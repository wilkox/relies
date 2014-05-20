#!/usr/bin/env perl

#################
###           ###
###  PREAMBLE ###
###           ###
#################

use Modern::Perl 2013;
use autodie;
use Getopt::Long;
use Cwd 'abs_path';
use File::Slurp;
use DateTime::Format::ISO8601;
use DateTime::Format::Strptime;
use Term::ANSIColor;
$|++;

#Formatter to write ISO8601 timestamps
# From https://movieos.org/blog/2006/perl-datetime-iso8601/
my $ISO8601Formatter = DateTime::Format::Strptime->new( pattern => "%{iso8601_with_tz}" );
sub DateTime::iso8601_with_tz {
  my $self = shift;
  my $val = $self->strftime('%FT%T%z');
  $val =~ s/(\d\d)$/:$1/;
  return $val;
}

#Get the git repository root path
my $gitroot = `git rev-parse --show-toplevel` or die "";
chomp $gitroot;

my $reliesFile = $gitroot . "/.relies";

#######################################
###                                 ###
###  BEGINNING OF CLASS DEFINITIONS ###
###                                 ###
#######################################

package Node {

  use Moose;

  #The path passed to relies
  has 'passed_path', is => 'ro', isa => 'Str';

  #Parents of this file (i.e. reliances explicitly set by the user)
  has 'parents', is => 'ro', isa => 'ArrayRef';

  #Safe flag
  has 'safe', is => 'ro', isa => 'Int';

  #Get the git modification status of a file
  sub has_been_modified {

    my $self = shift;
    my $fileName = $self->passed_path; #TODO fix handling of paths
    my $gitStatus = `git status -s $fileName`;
    my $hasBeenModified = $gitStatus eq "" ? 0 : 1;
    return $hasBeenModified;

  }

  #Get the last modified time for a file
  #  Last modified time is defined as:
  #    If there are no local modifications to the file:
  #      Timestamp for last git commit referencing that file
  #    If there are local modifications to the file:
  #      Timestamp for last filesystem modification
  sub last_modified {

    my $self = shift;
    my $modTime;
    my $hasBeenModified = $self->has_been_modified;
    my $fileName = $self->passed_path; #TODO fix handling of paths

    #If there are no local modifications, use the
    # git commit timestamp
    if (! $hasBeenModified) {

      my $gitTime = `git log -1 --format="%ad" --date=iso $fileName`;

      #Need to do a little parsing on date as git doesn't output
      # correct ISO8601 format (thanks...)
      my $ISO8601 = qr/^(?<date>\d{4}-\d{2}-\d{2})\s(?<time>\d{2}:\d{2}:\d{2})\s\+(?<timezonehour>\d{2})(?<timezoneminute>\d{2})$/;
      die "ERROR: 'git log --date=iso' returned a non-ISO8601 formatted date\n" unless $gitTime =~ /$ISO8601/;
      $gitTime = $+{date} . "T" . $+{time} . "+" . $+{timezonehour} . ":" . $+{timezoneminute};
      $modTime = DateTime::Format::ISO8601->parse_datetime($gitTime);
    
    #If there are local modifications, use the filesystem's
    # last modified timestamp
    } else {

      my $fsTime = (stat($fileName))[9];
      $modTime = DateTime->from_epoch( epoch => $fsTime );
    
    }

    $modTime->set_formatter($ISO8601Formatter);
    return $modTime;

  }

  #All ancestors for a child
  sub ancestors {

    my $self = shift;
    say "Called ancestors on ", $self->passed_path;
    my %ancestors;

    foreach my $parent (@{$self->parents}) {
      $ancestors{$parent}++;
      $ancestors{$_}++ for &ancestors($parent);
    }

    return [ keys(%ancestors) ];

  }

}


say "Beginning OO tests";

say "Reading reliances...";
my @allFiles = &read_reliances;

foreach (@allFiles) {

  say "Passed path is ", $_->passed_path;

  say "I've been modified" if $_->has_been_modified;

  say "Last modified time is ", $_->last_modified;

  say "My parents are:";
  say for @{$_->parents};

  say "My ancestors are:";
  say for @{$_->ancestors};

}

exit;

###############################
###                         ###
###  BEGINNING OF MAIN LOOP ###
###                         ###
###############################

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

#If no children given or './' or '.' given, glob the current directory
if (@children == 0 or $children[0] eq '.' or $children[0] eq './') {
  @children = glob('./*');
}

#Hash storing reliances
# Structure is simple: %reliances{Child}{Parent}
# We use hash for parents instead of array because it makes
# in-place edits easier
my %reliances;

#Hash storing safe values
my %isSafe;

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
  $isSafe{$_} = 1 for @safe;

  #Make unsafe
  $isSafe{$_} = 0 for @unsafe;

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
  &print_reliances($_) for @children;

  #Done
  exit;

}

die "ERROR: Somehow escaped the main loop without exiting\n";
###########################################################
###                                                     ###
### END OF CLASS DEFINITIONS - BEGINNING OF SUBROUTINES ###
###                                                     ###
###########################################################

#Return a list of ancestors with a mod time > than this file's mod time
sub young_ancestors {

  my $file = shift;
  my $modTime = &last_modified($file);
  my @ancestors = &ancestors($file);
  my @youngAncestors;

  foreach my $ancestor (@ancestors) {
    next if $isSafe{$ancestor};
    my $ancestorModTime = &last_modified($ancestor);
    my $compare = DateTime->compare($ancestorModTime, $modTime);
    push(@youngAncestors, $ancestor) if $compare == 1;
  }
  return @youngAncestors;
}

#Print reliances
sub print_reliances {

  my $child = shift;

  #Skip if child is safe and full has not been requested
  return if $isSafe{$child} and not $full;

  my @parents = keys %{$reliances{$child}};

  #Choose the appropriate subset of antecessors
  # to print
  my @antecessors;
  #If the full option was given, print all ancestors
  if ($full) {
    @antecessors = &ancestors($child);
  
  #If the full option was not given, print any problematic
  # ancestors
  } else {

    @antecessors = &young_ancestors($child);
  }

  #If there are not antecessors, don't print anything
  return if @antecessors == 0;

  &print_colourised($child);
  print " relies on\n";
  foreach my $antecessor (@antecessors) {
    print "   ";
    &print_colourised($antecessor);
    say "\t";
  }

}

#Print a file, colourised by status
sub print_colourised { 

  my $file = shift;
  my $hasYoungAncestors = scalar &young_ancestors($file);

  #Check for modifications to this file or ancestors
  my $hasBeenModified = &has_been_modified($file);

  # Green = no modifications in file, no reliance problems
  # Blue = safed and no modifications
  # Magenta = safed with modifications
  # Yellow = modifications in file, no reliance problems
  # Red = reliance problems
  my $colour;
  
  #Bold blue if safed and no modifications
  if ($isSafe{$file} and not $hasBeenModified) {
    $colour = 'blue';

  #Magenta if safed and modifications
  } elsif ($isSafe{$file} and $hasBeenModified) {
    $colour = 'magenta';

  #Red if there are reliance problems
  } elsif ($hasYoungAncestors) {
    $colour = 'red';

  #Yellow if there are local modifications but no reliance problems
  } elsif ((not $hasYoungAncestors) and $hasBeenModified) {
    $colour = 'yellow';

  #Green if there are no local modifications and no reliance problems
  } elsif ((not $hasYoungAncestors) and (not $hasBeenModified)) {
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
    say "No .relies for this repository - type 'relies init'"; #TODO implement 'relies init'
    return;
  }

  open RELIES, "<", $reliesFile;
  my @children;
  while (<RELIES>) {
    chomp;
    my @row = split(/\t/, $_);
    (my $passedPath, my $safe, my @parents) = @row;
    my $child = Node->new( passed_path => $passedPath, safe => $safe, parents => [ @parents ]);
    push(@children, $child);
  }
  close RELIES;

  return @children;

}

#Add new reliances
sub add_parents {

  (my $child, my @parents) = @_;

  #Check for loops
  foreach my $parent (@parents) {
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

    #If there is no safe value for this child,
    # set to 0
    my $isSafe = exists $isSafe{$child} ? $isSafe{$child} : 0;

    my $parents = join("\t", keys(%{$reliances{$child}}));
    say RELIES $child . "\t" . $isSafe . "\t" . $parents;
  
  }
  close RELIES;

}
