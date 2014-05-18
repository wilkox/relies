#!/usr/bin/perl

#Preamble
use Modern::Perl 2013;
use autodie;
use Getopt::Long;
use Cwd 'abs_path';
use File::Slurp;
$|++;

#Get the git repository root path
my $gitroot = `git rev-parse --show-toplevel` or die "";
chomp $gitroot;

my $reliesFile = $gitroot . "/.relies";

#Parse command line options
my @children;
my @parents;
my @bereaved;

GetOptions (

  "on=s{,}" => \@parents,
  "off=s{,}" => \@bereaved

);

#Mop any remaining arguments into @children
@children = @ARGV;

#Validate all files
sub validate_file {

  my ($file) = @_;

  #Get the absolute path
  my $absPath = abs_path($file);

  #Ensure the file exists
  die "ERROR: Cannot find file $file\n" unless -e $absPath;

  #Ensure git knows about the file 
  die "ERROR: Git doesn't seem to know about $file\nRun 'git add $file' first\n" unless `git ls-files $absPath --error-unmatch 2> /dev/null`;

}

&validate_file($_) for @children;
&validate_file($_) for @parents;
&validate_file($_) for @bereaved;

#Hash storing reliances
# Structure is simple: %reliances{Child}{Parent}
# We use hash for parents instead of array because it makes
# in-place edits easier
my %reliances;

#Read existing reliances in
&read_reliances;
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
#TODO checks against loops
sub add_parents {

  (my $child, my @parents) = @_;
  $reliances{$child}{$_}++ for @parents;

}

&add_parents($_, @parents) for @children;

#Remove obsolete reliances
sub remove_parents {

  (my $child, my $bereaved) = @_;
  delete($reliances{$child}{$_}) for @bereaved;

}

#Write reliances to file
&write_reliances;
sub write_reliances { 

  open RELIES, ">", $reliesFile;
  foreach my $child (keys %reliances) {
  
    my $parents = join("\t", keys(%{$reliances{$child}}));
    say RELIES $child . "\t" . $parents;
  
  }
  close RELIES;

}
