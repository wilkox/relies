#!/usr/bin/env perl

################
###          ###
### PREAMBLE ###
###          ###
################

use Modern::Perl 2013;
use autodie;
use Getopt::Long;
use Cwd 'abs_path';
use File::Slurp;
use DateTime::Format::ISO8601;
use DateTime::Format::Strptime;
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

#Store for Node objects
# Key: passed path
# Value: obj
my %node;

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
#TODO need to implement this with conversion to git paths
#if (@children == 0 or $children[0] eq '.' or $children[0] eq './') {
#@children = glob('./*');
#}

#######################################
###                                 ###
###  BEGINNING OF CLASS DEFINITIONS ###
###                                 ###
#######################################

package Node {

  use Moose;
  use Term::ANSIColor;

  #The path passed to relies
  has 'git_path', is => 'ro', isa => 'Str';

  #Parents of this file (i.e. reliances explicitly set by the user)
  has 'parents', is => 'rw', isa => 'ArrayRef';

  #Safe flag
  has 'safe', is => 'rw', isa => 'Int';

  #Get the git modification status of a file
  #TODO redefine as an attribute to prevent recalculation
  sub has_been_modified {

    my $self = shift;
    my $fileName = $self->git_path; #TODO fix handling of paths
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
    my $fileName = $self->git_path; #TODO fix handling of paths

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
    my %ancestors;

    foreach my $parentGitPath (@{$self->parents}) {
      die unless exists $node{$parentGitPath};
      my $parent = $node{$parentGitPath};
      $ancestors{$parentGitPath}++;
      $ancestors{$_}++ for @{$node{$parentGitPath}->ancestors};
    }

    return [ keys(%ancestors) ];

  }

  #Ancestors with a mod time > than this file's mod time
  sub young_ancestors {

    my $self = shift;
    my $modTime = $self->last_modified;
    my @ancestors = @{$self->ancestors};
    my @youngAncestors;

    foreach my $ancestor (@ancestors) {
      next if $node{$ancestor}->safe;
      my $ancestorModTime = $node{$ancestor}->last_modified;
      my $compare = DateTime->compare($ancestorModTime, $modTime);
      push(@youngAncestors, $ancestor) if $compare == 1;
    }
    return [ @youngAncestors ];
  }

  #Convenience
  #TODO redefine as attribute to prevent recalculation
  sub has_young_ancestors {
    my $self = shift;
    return scalar @{$self->young_ancestors};
  }

  #Print a file, colourised by status
  sub printf { 

    my $self = shift;

    # Green = no modifications in file, no reliance problems
    # Blue = safed and no modifications
    # Magenta = safed with modifications
    # Yellow = modifications in file, no reliance problems
    # Red = reliance problems
    
    #Bold blue if safed and no modifications
    if ($self->safe and not $self->has_been_modified) {
      print color 'blue';

    #Magenta if safed and modifications
    } elsif ($self->safe and $self->has_been_modified) {
      print color 'magenta';

    #Red if there are reliance problems
    } elsif ($self->has_young_ancestors) {
      print color 'red';

    #Yellow if there are local modifications but no reliance problems
    } elsif ((not $self->has_young_ancestors) and $self->has_been_modified) {
      print color 'yellow';

    #Green if there are no local modifications and no reliance problems
    } elsif ((not $self->has_young_ancestors) and (not $self->has_been_modified)) {
      print color 'green';

    #If there are reliance problems but no file modifications, something
    # has gone horribly wrong
    } else {
      die "ERROR: Something has gone horribly wrong";
    }

    print $self->git_path;
    print color 'reset';

  }

  #Print reliances
  sub printf_reliances {

    my $self = shift;

    #Skip if child is safe and full has not been requested
    return if $self->safe and not $full;

    my @parents = @{$self->parents};

    #Choose the appropriate subset of antecessors
    # to print
    my @antecessors;
    #If the full option was given, print all ancestors
    if ($full) {
      @antecessors = @{$self->ancestors};
    
    #If the full option was not given, print any problematic
    # ancestors
    } else {

      @antecessors = @{$self->young_ancestors};
    }

    #If there are not antecessors, don't print anything
    return if @antecessors == 0;

    $self->printf;
    print " relies on\n";
    foreach my $antecessor (@antecessors) {
      print "   ";
      $node{$antecessor}->printf;
      say "\t";
    }

  }


}

###############################
###                         ###
###  BEGINNING OF MAIN LOOP ###
###                         ###
###############################

#Safeing
if (@safe || @unsafe) {

  #Incompatible options
  die "ERROR: Can't combine --safe or --unsafe with --on or --off\n" if @parents || @bereaved;
  warn "WARNING: ignoring --full\n" if $full;

  #TODO need to convert passed paths to git paths

  #Validate files
  &validate_file($_) for (@safe, @unsafe);

  #Read reliances store into memory
  &read_reliances;

  #Check that all the safe/unsafe files are actually
  # known to relies
  foreach (@safe, @unsafe) {
    die "ERROR: $_ does not have any reliances\n" unless exists $node{$_};
  }

  #Make safe
  $node{$_}->safe(1) for @safe;

  #Make unsafe
  $node{$_}->safe(0) for @unsafe;

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
  $node{$_}->printf_reliances for @children;

  #Done
  exit;

}

die "ERROR: Somehow escaped the main loop without exiting\n";
###################################################
###                                             ###
### END OF MAIN LOOP - BEGINNING OF SUBROUTINES ###
###                                             ###
###################################################

#Validate a file
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
  while (<RELIES>) {
    chomp;
    my @row = split(/\t/, $_);
    (my $gitPath, my $safe, my @parents) = @row;
    my $child = Node->new( git_path => $gitPath, safe => $safe, parents => [ @parents ]);
    $node{$gitPath} = $child;
  }
  close RELIES;

}

#Add new reliances
sub add_parents {

  (my $child, my @parents) = @_;

  #Create nodes for child and parent files if they are new
  foreach my $gitPath (@_) {
    next if exists $node{$gitPath};
    my $newNode = Node->new( git_path => $gitPath, safe => 0, parents => [ ]); #TODO git path
    $node{$gitPath} = $newNode;
  }

  #Check for loops
  foreach my $parent (@parents) {
    my %ancestors = map { $_ => 1 } @{$node{$parent}->ancestors};
    next unless exists $ancestors{$child};
    die "ERROR: $child can't rely on $parent as this will create a loop\n";
  }

  #Join old and new parents
  my %parents = map { $_ => 1 } @{$node{$child}->parents};
  $parents{$_}++ for @parents;
  $node{$child}->parents([ keys %parents ]);

}

#Remove obsolete reliances
sub remove_parents {

  (my $child, my $bereaved) = @_;
  my %oldParents = map { $_ => 1 } @{$node{$child}->parents};
  delete $oldParents{$_} for @bereaved;
  @{$node{$child}->parents} = keys %oldParents;

}

#Write reliances to file
sub write_reliances { 

  open RELIES, ">", $reliesFile;
  foreach my $node (keys %node) {

    my $parents = join("\t", @{$node{$node}->parents});
    say RELIES $node{$node}->git_path . "\t" . $node{$node}->safe . "\t" . $parents;
  
  }
  close RELIES;

}
