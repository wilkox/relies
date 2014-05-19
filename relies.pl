#!/usr/bin/env perl

#Preamble
use Modern::Perl 2013;
use autodie;
use Getopt::Long;
use Cwd 'abs_path';
use File::Slurp;
use DateTime::Format::ISO8601;
$|++;

#Get the git repository root path
my $gitroot = `git rev-parse --show-toplevel` or die "";
chomp $gitroot;

my $reliesFile = $gitroot . "/.relies";

#Parse command line options
my @children;
my @parents;
my @bereaved;
my $full;

GetOptions (

  "on=s{,}" => \@parents,
  "off=s{,}" => \@bereaved,
  "full" => \$full  #Flag to request full expansion when listing parents

);

#Mop any remaining arguments into @children
@children = @ARGV;

#Hash storing reliances
# Structure is simple: %reliances{Child}{Parent}
# We use hash for parents instead of array because it makes
# in-place edits easier
my %reliances;

#If parents and/or bereaved were provided,
# add/remove as necessary
if (@parents || @bereaved) {

  #Warn about flags being ignored
  warn "WARNING: ignoring --full\n" if $full;

  #Validate files
  &validate_file($_) for @children;
  &validate_file($_) for @parents;
  &validate_file($_) for @bereaved;

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

}

#Get the last modified time for a file
#  Last modified time is defined as:
#    If there are no local modifications to the file:
#      Timestamp for last git commit referencing that file
#    If there are local modifications to the file:
#      Timestamp for last filesystem modification
sub last_modified {

  my $file = shift;
  my $modTime;

  #Get the git status of the file
  my $gitStatus = `git status -s $file`;

  #If there are no local modifications, use the
  # git commit timestamp
  if ($gitStatus eq "") {

    my $gitTime = `git log -1 --format="%ad" --date=iso $file`;

    #Need to do a little parsing on date as git doesn't output
    # correct ISO8601 format (thanks...)
    my $ISO8601 = qr/^(?<date>\d{4}-\d{2}-\d{2})\s(?<time>\d{2}:\d{2}:\d{2})\s\+(?<timezonehour>\d{2})(?<timezoneminute>\d{2})$/;
    die "ERROR: 'git log --date=iso' returned a non-ISO8601 formatted date\n" unless $gitTime =~ /$ISO8601/;
    $gitTime = $+{date} . "T" . $+{time} . "+" . $+{timezonehour} . ":" . $+{timezoneminute};
    $modTime = DateTime::Format::ISO8601->parse_datetime($gitTime);
    $modTime = $modTime->datetime();
  
  #If there are local modifications, use the filesystem's
  # last modified timestamp
  } else {

    my $fsTime = (stat($file))[9];
    $modTime = DateTime->from_epoch( epoch => $fsTime );
    $modTime = $modTime->datetime();
  
  }
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

  say "$child relies on:";
  say "\t$_\t", &last_modified($_) for @antecessors;

}

#Validate files
sub validate_file {

  my ($file) = @_;

  #Get the absolute path
  my $absPath = abs_path($file);

  #Ensure the file exists
  die "ERROR: Cannot find file $file\n" unless -e $absPath;

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
  
    my $parents = join("\t", keys(%{$reliances{$child}}));
    say RELIES $child . "\t" . $parents;
  
  }
  close RELIES;

}
