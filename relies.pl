#!/usr/bin/env perl

################
###          ###
### PREAMBLE ###
###          ###
################

use Modern::Perl 2013;
use autodie;
use Getopt::Long;
use Cwd::Ext 'abs_path_nd';
use File::Slurp;
use DateTime::Format::ISO8601;
use DateTime::Format::Strptime;
use DateTime::Format::Human::Duration;
use File::Spec;
use Graph::Easy;
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
my $gitRoot = `git rev-parse --show-toplevel` or die "\n";
chomp $gitRoot;

my $reliesFile = $gitRoot . "/.relies";

#Store for Node objects
# Key: passed path
# Value: obj
my %node;

#Parse command and options
my $command;
my @parents; #Special infix option
my @bereaved; #Special infix option
my @fileList;
my %validCommand = map { $_ => 1 } qw(safe unsafe whither whence family parents children status);
$command = shift(@ARGV) if @ARGV > 0 and $validCommand{$ARGV[0]};

GetOptions (

  #Infix options
  "on=s{,}" => \@parents,
  "off=s{,}" => \@bereaved,

);

#Call foul if mix of infix and command
die "ERROR: can't mix $command with --on\n" if $command and @parents;
die "ERROR: can't mix $command with --off\n" if $command and @bereaved;

#Mop any remaining arguments into @fileList
@fileList = @ARGV;

#If no command or infix operator was passed,
# set command to default 'status'
$command = 'status' if not $command and not @parents and not @bereaved;

#If we are using a command (i.e. not infix)
# and no list of files given, or './' or '.' given, 
# glob the current directory as @fileList
if ($command and (@fileList == 0 or $fileList[0] eq '.' or $fileList[0] eq './')) {
  @fileList = glob('./*');
  @fileList = grep { !-d $_ } @fileList;
}

#Validate passed files and convert to git paths
@fileList = map { &to_git_path($_) } (@fileList);
@parents = map { &to_git_path($_) } (@parents);
@bereaved = map { &to_git_path($_) } (@bereaved);

######################################
###                                ###
### BEGINNING OF CLASS DEFINITIONS ###
###                                ###
######################################

package Node {

  use Moose;
  use Term::ANSIColor;

  #The path passed to relies
  has 'git_path', is => 'ro', isa => 'Str';

  #Parents of this file (i.e. reliances explicitly set by the user)
  has 'parents', is => 'rw', isa => 'ArrayRef';

  #Safe flag
  has 'safe', is => 'rw', isa => 'Int';

  #Touch date
  has 'touch', is => 'rw', isa => 'Str';

  #Path relative to current working directory
  #TODO redefine as an attribute to prevent recomputation
  sub relative_path {

    my $self = shift;
    my $relativePath = File::Spec->abs2rel($gitRoot . "/" . $self->git_path);
    return $relativePath;

  }

  #Get the git modification status of a file
  #TODO redefine as an attribute to prevent recalculation
  sub has_been_modified {

    my $self = shift;
    my $fileName = $self->relative_path;
    my $gitStatus = `git status -s $fileName`;
    my $hasBeenModified = $gitStatus eq "" ? 0 : 1;
    return $hasBeenModified;

  }

  #Format the last modified time, in natural language
  sub last_modified_natural {

    my $self = shift;
    my $span = DateTime::Format::Human::Duration->new();
    my $now = DateTime->now();
    my $ago = $span->format_duration_between($now, $self->last_modified, 'significant_units' => 1);
    return $ago;
  
  }

  #Get the last modified time for a file
  #  Last modified time is defined as:
  #    If there are no local modifications to the file:
  #      Timestamp for last git commit referencing that file
  #    If there are local modifications to the file:
  #      Timestamp for last filesystem modification
  #
  # Returns a Date::Time object
  sub last_modified {

    my $self = shift;
    my $modTime;
    my $hasBeenModified = $self->has_been_modified;
    my $fileName = $self->relative_path;

    #If there are no local modifications, use the
    # git commit timestamp
    if (! $hasBeenModified) {

      my $gitTime = `git log -1 --format="%ad" --date=iso $fileName`;

      #Need to do a little parsing on date as git doesn't output
      # correct ISO8601 format (thanks...)
      my $ISO8601 = qr/^(?<date>\d{4}-\d{2}-\d{2})\s(?<time>\d{2}:\d{2}:\d{2})\s\+(?<timezonehour>\d{2})(?<timezoneminute>\d{2})$/;
      die "ERROR: 'git log --date=iso' returned a non-ISO8601 formatted date\n$gitTime\n" unless $gitTime =~ /$ISO8601/;
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

  #All ancestors of a node
  #TODO cache (careful!)
  sub ancestors {

    my $self = shift;
    my %ancestors;

    foreach my $parentGitPath (@{$self->parents}) {
      my $parent = $node{$parentGitPath};
      $ancestors{$parentGitPath}++;
      $ancestors{$_}++ for @{$node{$parentGitPath}->ancestors};
    }

    return [ keys(%ancestors) ];

  }

  #All descendants of a node
  sub descendants {

    my $self = shift;
    my %descendants;

    foreach my $childGitPath (@{$self->children}) {
      my $child = $node{$childGitPath};
      $descendants{$childGitPath}++;
      $descendants{$_}++ for @{$node{$childGitPath}->children};
    }

    return [ keys(%descendants) ];
  
  }

  #Descendants with a mod time < than this file's mod time
  #TODO cache
  sub old_descendants {

    my $self = shift;
    my $modTime = $self->last_modified;
    my @descendants = @{$self->descendants};
    my @oldDescendants;

    foreach my $descendant (@descendants) {
      next if $node{$descendant}->safe;
      my $descendantModFime = $node{$descendant}->last_modified;
      my $compare = DateTime->compare($descendantModFime, $modTime);
      push(@oldDescendants, $descendant) if $compare == 1;
    }
    return [ @oldDescendants ];
  }

  #Ancestors with a mod time > than this file's mod time
  #TODO cache
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

  #All children of a node
  #TODO cache
  sub children {
  
    my $self = shift;
    my %children;

    foreach my $potentialChild (keys %node) {
      my %actualParents = map { $_ => 1 } @{$node{$potentialChild}->parents};
      $children{$potentialChild}++ if exists $actualParents{$self->git_path};
    }

    return [ keys %children ];
  
  }

  #Convenience
  #TODO redefine as attribute to prevent recalculation
  sub has_old_descendants {
    my $self = shift;
    return scalar @{$self->old_descendants};
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

    # Blue    : safed
    # Green   : no young ancestors, no old descendants
    # Yellow  : no young ancestors, has old descendants
    # Red     : has young ancestors
    
    #Blue if safed
    if ($self->safe and not $self->has_been_modified) {
      print color 'blue';
      print $self->relative_path;
      print color 'reset';

    #Red if there are young ancestors
    } elsif ($self->has_young_ancestors) {
      print color 'red';
      print $self->relative_path;
      print color 'bold white';
      print " [" . $self->last_modified_natural . " ago]";
      print color 'reset';

    #Yellow if there are old descentants but no young ancestors
    } elsif ((not $self->has_young_ancestors) and $self->has_old_descendants) {
      print color 'yellow';
      print $self->relative_path;
      print color 'bold white';
      print " [" . $self->last_modified_natural . " ago]";
      print color 'reset';

    #Green if there are no young ancestors and no old descendants
    } elsif ((not $self->has_young_ancestors) and (not $self->has_old_descendants)) {
      print color 'green';
      print $self->relative_path;
      print color 'reset';

    #If there are reliance problems but no file modifications, something
    # has gone horribly wrong
    } else {
      die "ERROR: Something has gone horribly wrong";
    }

  }

  #Print reliances
  sub printf_reliances {

    my $self = shift;

    my @parents = @{$self->parents};
    my %antecessors = map { $_ => 1 } (@{$self->parents}, @{$self->young_ancestors});

    #If there are not antecessors, don't print anything
    return if keys %antecessors == 0;

    $self->printf;
    print " relies on:\n";
    foreach my $antecessor (keys %antecessors) {
      print "   ";
      $node{$antecessor}->printf;
      print "\n";
    }

  }

}

##############################
###                        ###
### BEGINNING OF MAIN LOOP ###
###                        ###
##############################

#If parents and/or bereaved were provided,
# add/remove as necessary
if (@parents || @bereaved) {

  #Read reliances store into memory
  &read_reliances;

  #Update as needed
  &add_parents($_, @parents) for @fileList;
  &remove_parents($_, @parents) for @fileList;
  
  #Write reliances store to file
  &write_reliances;

  #Done
  say "OK";
  exit;

#Safeing/unsafing
} elsif ($command eq "safe" or $command eq "unsafe") {

  #Read reliances store into memory
  &read_reliances;

  #Check that all the safe/unsafe files are actually
  # known to relies
  foreach (@fileList) {
    die "ERROR: $_ does not have any reliances\n" unless exists $node{$_};
  }

  #Make safe/unsafe
  my $safeValue = $command eq 'safe' ? 1 : 0;
  $node{$_}->safe($safeValue) for @fileList;

  #Write to file
  &write_reliances;

  #Done
  say "OK";
  exit;

#Graph descendants
} elsif ($command eq 'whither') {

  #Only plot one file
  die "ERROR: 'whither' only works for a single file\n" if @fileList > 1;
  my $whither = $fileList[0];

  #Read reliances store into memory
  &read_reliances;

  #Generate list of unique edges in descendant graph
  my %edges;
  foreach my $descendant ($whither, @{$node{$whither}->descendants}) {
    foreach my $child (@{$node{$descendant}->children}) {
      my $descendantPath = $node{$descendant}->relative_path;
      my $childPath = $node{$child}->relative_path;
      $edges{$descendantPath, $childPath} = [ $descendantPath, $childPath ];
    }
  }

  if (keys %edges == 0) {
    say "No known descendants of $whither";
    exit;
  }

  #Construct Graph::Easy graph
  my $graph = Graph::Easy->new();
  $graph->add_edge(@{$_}[0], @{$_}[1]) for values %edges;

  print $graph->as_boxart();

  #Done
  exit;

#Graph ancestors
#TODO change to case/switch
} elsif ($command eq 'whence') {

  #Only plot one file
  die "ERROR: 'whence' only works for a single file\n" if @fileList > 1;
  my $whence = $fileList[0];

  #Read reliances store into memory
  &read_reliances;

  #Generate list of unique edges in ancestor graph
  my %edges;
  foreach my $ancestor ($whence, @{$node{$whence}->ancestors}) {
    foreach my $parent (@{$node{$ancestor}->parents}) {
      my $ancestorPath = $node{$ancestor}->relative_path;
      my $parentPath = $node{$parent}->relative_path;
      $edges{$ancestorPath, $parentPath} = [ $ancestorPath, $parentPath ];
    }
  }

  if (keys %edges == 0) {
    say "No known ancestors for $whence";
    exit;
  }

  #Construct Graph::Easy graph
  my $graph = Graph::Easy->new();
  $graph->add_edge(@{$_}[1], @{$_}[0]) for values %edges;

  print $graph->as_boxart();

  #Done
  exit;

#Graph immediate family
} elsif ($command eq 'family') {

  #Only show one file
  die "ERROR: 'family' only works for a single file\n" if @fileList > 1;
  my $file = $fileList[0];

  #Read reliances store into memory
  &read_reliances;

  #Exit if this file is unknown to relies
  exit unless exists $node{$file};

  #Generate edges for immediate family graph
  my %edges;
  foreach my $parent (@{$node{$file}->parents}) {
    $edges{$node{$parent}->relative_path, $file} = [ $node{$parent}->relative_path, $file ];
  }
  foreach my $child (@{$node{$file}->children}) {
    $edges{$file, $node{$child}->relative_path} = [ $file, $node{$child}->relative_path ];
  }

  if (keys %edges == 0) {
    say "$file has no immediate family";
    exit;
  }

  #Construct Graph::Easy graph
  my $graph = Graph::Easy->new();
  $graph->add_edge(@{$_}[0], @{$_}[1]) for values %edges;

  print $graph->as_boxart();

  #Done
  exit;

#Report the status of the listed files
} elsif ($command eq 'status') {

  #Read reliances store into memory
  &read_reliances;

  #Describe parents for children
  foreach (@fileList) {
    next unless exists $node{$_};
    $node{$_}->printf_reliances;
  }

  #Done
  exit;

#List parents
} elsif ($command eq 'parents') {

  #Only show one file
  die "ERROR: 'parents' only works for a single file\n" if @fileList > 1;
  my $file = $fileList[0];

  #Read reliances store into memory
  &read_reliances;

  #Is this a known file?
  exit unless exists $node{$file};

  #List parents
  say $node{$_}->relative_path for @{$node{$file}->parents};

  #Done
  exit;

#List children
} elsif ($command eq 'children') {

  #Only show one file
  die "ERROR: 'children' only works for a single file\n" if @fileList > 1;
  my $file = $fileList[0];

  #Read reliances store into memory
  &read_reliances;

  #Is this a known file?
  exit unless exists $node{$file};

  #List children
  say $node{$_}->relative_path for @{$node{$file}->children};

  #Done
  exit;

#Catch weirdness
} else {
  say "Command is $command";
  die "Something has gone terribly wrong";
}

###################################################
###                                             ###
### END OF MAIN LOOP - BEGINNING OF SUBROUTINES ###
###                                             ###
###################################################

#Validate a file
sub validate_file {

  my ($file) = @_;

  #Get the absolute path
  my $absPath = abs_path_nd($file);

  #Ensure the file exists
  die "ERROR: Can't find file $file\n" unless -e $absPath or -l $absPath;

  #Ensure the file is a file
  die "ERROR: $file is not a file\n" unless -f $absPath or -l $absPath;

  #Ensure git knows about the file 
  my $relativePath = File::Spec->abs2rel(abs_path_nd($file));
  die "ERROR: Git doesn't seem to know about $file\nRun 'git add $file' first\n" unless `git ls-files $relativePath --error-unmatch 2> /dev/null`;

}

#Read existing reliances in
sub read_reliances { 

  if (! -e $reliesFile) {
    say "No .relies for this repository - type 'touch .relies' to create one";
    return;
  }

  open RELIES, "<", $reliesFile;
  while (<RELIES>) {
    chomp;
    my @row = split(/\t/, $_);
    (my $gitPath, my $safe, my $touch, my @parents) = @row;
    my $child = Node->new( git_path => $gitPath, safe => $safe, touch => $touch, parents => [ @parents ]);
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
    my $newNode = Node->new( git_path => $gitPath, safe => 0, touch => 0, parents => [ ]);
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

    say RELIES join("\t", ($node{$node}->git_path, $node{$node}->safe, $node{$node}->touch, @{$node{$node}->parents}));
  
  }
  close RELIES;

}

#Convert a passed path to a git path
sub to_git_path {

  my $filePath = shift;
  &validate_file($filePath);
  my $relativePath = File::Spec->abs2rel(abs_path_nd($filePath), $gitRoot);
  return $relativePath;

}
