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


#Hash storing dependencies
my %dependencies;

#TODO read existing dependencies in

#Add new dependencies
#TODO checks against recursion
sub add_parents {

  (my $child, my @parents) = @_;
  $dependencies{$child}{$_}++ for @parents;

}

&add_parents($_, @parents) for @children;

#Remove obsolete dependencies
sub remove_parents {

  (my $child, my $bereaved) = @_;
  delete($dependencies{$child}{$_}) for @bereaved;

}

#Write new dependencies to file
sub prepare_for_output { 

  (my $child) = @_;
  my $parents = join("\t", keys(%{$dependencies{$child}}));
  return($child . "\t" . $parents . "\n");

}
write_file($reliesFile, map {&prepare_for_output($_)} @children);
