#!/usr/bin/env perl

#Preamble
use Modern::Perl 2013;
use autodie;
use Getopt::Long;
use Cwd 'abs_path';
use File::Slurp;
use DateTime::Format::ISO8601;
use DateTime::Format::Strptime;
use Term::ANSIColor;
$|++;

#Formatter to write ISO8601
# From https://movieos.org/blog/2006/perl-datetime-iso8601/
my $ISO8601Formatter = DateTime::Format::Strptime->new( pattern => "%{iso8601_with_tz}" );

#Get the git repository root path
my $gitroot = `git rev-parse --show-toplevel` or die "";
chomp $gitroot;

my $reliesFile = $gitroot . "/.relies";

#Parse command line options
my @parents;
my @bereaved;
my $full;
my @safe;
my @unsafe;

GetOptions (

  "on=s{,}" => \@parents,
  "off=s{,}" => \@bereaved,
  "full" => \$full,
  "safe=s{,}" => \@safe,
  "unsafe=s{,}" => \@unsafe

);

#Mop any remaining arguments into @children
my @children = @ARGV;

#Hash storing reliances
# Structure is simple: %reliances{Child}{Parent}
# We use hash for parents instead of array because it makes
# in-place edits easier
my %reliances;

#Hash storing safe times
# File -> Safe time (ISO8601)
my %safeTime;

#Safeing
if (@safe || @unsafe) {

  #Incompatible options
  die "ERROR: Can't combine --safe or --unsafe with --on or --off\n" if @parents || @bereaved;
  warn "WARNING: ignoring --full\n" if $full;

  #Validate files
  &validate_file($_) for (@safe, @unsafe);

  #Read reliances store into memory
  &read_reliances;

  #Check that all the safe/unsafe files are actually
  # known to relies
  foreach (@safe, @unsafe) {
    die "ERROR: $_ does not have any reliances\n" unless exists $reliances{$_};
  }

  #Make safe
  my $now = DateTime->now(time_zone => 'local');
  $now->set_formatter($ISO8601Formatter);
  $safeTime{$_} = $now for @safe;

  #Make unsafe
  $safeTime{$_} = "" for @unsafe;

  #Write to file
  &write_reliances;

  #Done
  say "OK";
  exit;


#If parents and/or bereaved were provided,
# add/remove as necessary
} elsif (@parents || @bereaved) {

  #Warn about flags being ignored
  die "ERROR: Can't combine --safe or --unsafe with --on or --off\n" if @safe || @unsafe;
  warn "WARNING: ignoring --full\n" if $full;

  #Validate files
  &validate_file($_) for (@children, @parents, @bereaved);

  #Read reliances store into memory
  &read_reliances;

  #Update as needed
  &add_parents($_, @parents) for @children;
  &remove_parents($_, @parents) for @children;

  #Clean up reliances store
  &do_housekeeping;

  #Write reliances store to file
  &write_reliances;

  #Done
  say "OK";
  exit;

#If no options were provided, give information about
# the listed child(ren)
} else {

  #Validate the files
  &validate_file($_) for @children;

  #Read reliances store into memory
  &read_reliances;

  #Describe parents for children
  &print_parents($_) for @children;

  #Done
  exit;

}

die "ERROR: Somehow escaped the main loop without exiting\n";
###################################################
###                                             ###
### END OF MAIN LOOP - BEGINNING OF SUBROUTINES ###
###                                             ###
###################################################

#Report the status of a file
# 0 = No ancestor has a mod time > this file's mod time
# 1 = An ancestor has a mod time > this file's mod time
sub relies_status {

  my $file = shift;
  my $status = 0;

  $status++ if &young_ancestors($file) > 0;

  return $status;

}

#Return a list of ancestors with a mod time > than this file's mod time
sub young_ancestors {

  my $file = shift;
  my $modTime = &last_modified($file);
  my @ancestors = &ancestors($file);
  my @youngAncestors;

  foreach my $ancestor (@ancestors) {
    my $ancestorModTime = &last_modified($ancestor);
    my $compare = DateTime->compare($ancestorModTime, $modTime);
    push(@youngAncestors, $ancestor) if $compare == 1;
  }
  return @youngAncestors;
}

#Get the last modified time for a file
#  Last modified time is defined as:
#    If there are no local modifications to the file:
#      Timestamp for last git commit referencing that file
#    If there are local modifications to the file:
#      Timestamp for last filesystem modification
#    If file has been safed and safed time is > last modified time:
#      Safe time
sub last_modified {

  my $file = shift;
  my $modTime;
  my $gitModified = &git_modified($file);

  #If there are no local modifications, use the
  # git commit timestamp
  if (! $gitModified) {

    my $gitTime = `git log -1 --format="%ad" --date=iso $file`;

    #Need to do a little parsing on date as git doesn't output
    # correct ISO8601 format (thanks...)
    my $ISO8601 = qr/^(?<date>\d{4}-\d{2}-\d{2})\s(?<time>\d{2}:\d{2}:\d{2})\s\+(?<timezonehour>\d{2})(?<timezoneminute>\d{2})$/;
    die "ERROR: 'git log --date=iso' returned a non-ISO8601 formatted date\n" unless $gitTime =~ /$ISO8601/;
    $gitTime = $+{date} . "T" . $+{time} . "+" . $+{timezonehour} . ":" . $+{timezoneminute};
    $modTime = DateTime::Format::ISO8601->parse_datetime($gitTime);
  
  #If there are local modifications, use the filesystem's
  # last modified timestamp
  } else {

    my $fsTime = (stat($file))[9];
    $modTime = DateTime->from_epoch( epoch => $fsTime );
  
  }

  #If the file has been safed and the safe time > the mod time
  # that would be used otherwise, use the safe time
  if ($safeTime{$file}) {
    $modTime = $safeTime{$file} if $safeTime{$file} > $modTime;
  }

  $modTime->set_formatter($ISO8601Formatter);
  return $modTime;

}

#Get full list of ancestors for a file
#IMPORTANT: this depends on all relationship
# being properly validated for non-circularity
sub ancestors {

  my $child = shift;
  my %ancestors;

  foreach my $parent (keys %{$reliances{$child}}) {
    $ancestors{$parent}++;
    $ancestors{$_}++ for &ancestors($parent);
  }

  keys(%ancestors);

}

#Print reliances
sub print_parents {

  my $child = shift;
  my @parents = keys %{$reliances{$child}};
  return if @parents == 0;

  #Choose the appropriate subset of antecessors
  # to print
  my @antecessors = $full ? &ancestors($child) : @parents;

  &colourise($child);
  say " relies on:";
  foreach my $antecessor (@antecessors) {
    print "\t";
    &colourise($antecessor);
    say "\t";
  }

}

#Get the git modification status of a file
sub git_modified {

  my $file = shift;
  my $gitStatus = `git status -s $file`;
  my $gitModified = $gitStatus eq "" ? 0 : 1;
  return $gitModified;

}

#Print a file, colourised by status
sub colourise { 

  my $file = shift;
  my $reliesProblem = &relies_status($file);

  #Check for modifications to this file or ancestors
  my $filesModified = &git_modified($file);
  $filesModified += &git_modified($_) for &ancestors($file);

  # Green = no local modifications in file/ancestory, no reliance problems
  # Yellow = local modifications in file/ancestory, no reliance problems
  # Red = reliance problems
  my $colour;
  
  #Red if there are reliance problems
  if ($reliesProblem) {
    $colour = 'red';

  #Yellow if there are local modifications but no reliance problems
  } elsif ((not $reliesProblem) and $filesModified) {
    $colour = 'yellow';

  #Green if there are no local modifications and no reliance problems
  } elsif ((not $reliesProblem) and (not $filesModified)) {
    $colour = 'green';

  #If there are reliance problems but no file modifications, something
  # has gone horribly wrong
  } else {
    die "ERROR: Something has gone horribly wrong";
  }

  print color $colour;
  print $file;
  print color 'reset';

}

#Validate files
sub validate_file {

  my ($file) = @_;

  #Get the absolute path
  my $absPath = abs_path($file);

  #Ensure the file exists
  die "ERROR: Can't find file $file\n" unless -e $absPath;

  #Ensure the file is a file
  die "ERROR: $file is not a file\n" unless -f $absPath;

  #Ensure git knows about the file 
  die "ERROR: Git doesn't seem to know about $file\nRun 'git add $file' first\n" unless `git ls-files $absPath --error-unmatch 2> /dev/null`;

}

#Read existing reliances in
sub read_reliances { 

  if (! -e $reliesFile) {
    say "No .relies for this repository - type 'relies init'";
    return;
  }

  open RELIES, "<", $reliesFile;
  while (<RELIES>) {
    chomp;
    my @row = split(/\t/, $_);
    my $child = shift(@row);
    my $safeTime = shift(@row);
    unless ($safeTime eq "") {
      $safeTime{$child} = DateTime::Format::ISO8601->parse_datetime($safeTime);
    }
    %{$reliances{$child}} = map { $_ => 1 } @row;
  }
  close RELIES;

}

#Add new reliances
sub add_parents {

  (my $child, my @parents) = @_;

  #Check for loops
  foreach my $parent (@parents) {
    #TODO trace the path
    my %ancestors = map { $_ => 1 } &ancestors($parent);
    next unless exists $ancestors{$child};
    die "ERROR: $child can't rely on $parent as this will create a loop\n";
  }

  $reliances{$child}{$_}++ for @parents;

}

#Remove obsolete reliances
sub remove_parents {

  (my $child, my $bereaved) = @_;
  delete($reliances{$child}{$_}) for @bereaved;

}

#Housekeeping on reliances hash
sub do_housekeeping {

  #Remove any children with no parents
  foreach my $child (keys %reliances) {
    delete $reliances{$child} if keys %{$reliances{$child}} == 0;
  }

}

#Write reliances to file
sub write_reliances { 

  open RELIES, ">", $reliesFile;
  foreach my $child (keys %reliances) {

    #Get and format safe time, if it exists
    my $safeTime;
    if ($safeTime{$child}) {
      $safeTime = $safeTime{$child};
      $safeTime->set_formatter($ISO8601Formatter);
    } else {
      $safeTime = "";
    }

    my $parents = join("\t", keys(%{$reliances{$child}}));
    say RELIES $child . "\t" . $safeTime . "\t" . $parents;
  
  }
  close RELIES;

}

#Format DateTime objects as ISO8601 with time zone
#From https://movieos.org/blog/2006/perl-datetime-iso8601/
sub DateTime::iso8601_with_tz {
  my $self = shift;
  my $val = $self->strftime('%FT%T%z');
  $val =~ s/(\d\d)$/:$1/;
  return $val;
}
