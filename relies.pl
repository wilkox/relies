#!/usr/bin/env perl

################
###          ###
### PREAMBLE ###
###          ###
################

use Modern::Perl 2013;
use Moose::Meta::Attribute::Native::Trait::Array;
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
my %validCommand = map { $_ => 1 } qw(safe unsafe whither whence family parents children status touch untouch doctor);
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

  #Build the required attributes from the .relies line
  around BUILDARGS => sub { 
    shift; #Moose passes some other
    shift; # stuff that we don't want
    my $relies_line = shift;
    (my $git_path, my $safe, my $touch, my @parents) = split(/\t/, $relies_line);
    return {
      git_path => $git_path,
      safe => $safe,
      touch => $touch,
      parents => [ @parents ], 
    };
  };

  ###
  # These attributes come from .relies - they are required for each node and
  # are set at construction

  #The path passed to relies
  has 'git_path', is => 'ro', isa => 'Str', required => 1;
   
  #Parents of this file (i.e. reliances explicitly set by the user)
  has 'parents', 
    is => 'rw', 
    isa => 'ArrayRef', 
    auto_deref => 1,
    required => 1,
    ;
   
  #Safe flag
  has 'safe', is => 'rw', isa => 'Int', required => 1;
   
  #Touch date
  has 'touch', is => 'rw', isa => 'Str', required => 1;

  #
  ###

  ###
  # These attributes are lazy and are only populated when the relevent
  # accessor is called

  #The relative path
  has 'relative_path', is => 'ro', isa => 'Str', builder => '_build_relative_path', lazy => 1;
  
  #Has the file been modified?
  has 'has_been_modified', is => 'ro', isa => 'Int', builder => '_build_has_been_modified', lazy => 1;
  
  #Last modified DateTime
  has 'last_modified', is => 'ro', isa => 'DateTime', builder => '_build_last_modified', lazy => 1;
  
  #Is a touch in effect?
  has 'touch_in_effect', is => 'ro', isa => 'Int', builder => '_build_touch_in_effect', lazy => 1;
  
  #All ancestors of a node
  has 'ancestors', is => 'ro', isa => 'ArrayRef', auto_deref => 1, builder => '_build_ancestors', lazy => 1;
  
  #All descendants of a node
  has 'descendants', is => 'ro', isa => 'ArrayRef', auto_deref => 1, builder => '_build_descendants', lazy => 1;

  #Descendants with a mod time < than this file's mod time
  has 'old_descendants', is => 'ro', isa => 'ArrayRef', traits => ['Array'], handles => {has_old_descendants => 'count', all_old_descendants => 'elements'}, builder => '_build_old_descendants', lazy => 1;

  #Ancestors with a mod time > than this file's mod time
  has 'young_ancestors', is => 'ro', isa => 'ArrayRef', traits => ['Array'], handles => {has_young_ancestors => 'count', all_young_ancestors => 'elements'}, builder => '_build_young_ancestors', lazy => 1;
  
  #All children of a node
  has 'children', is => 'ro', isa => 'ArrayRef', auto_deref => 1, builder => '_build_children', lazy => 1;

  #
  ###

  #######################
  ###                 ###
  ### BUILDER METHODS ###
  ###                 ###
  #######################

  #All children of a node
  sub _build_children {
  
    my $self = shift;
    my %children;

    foreach my $potentialChild (keys %node) {
      my %actualParents = map { $_ => 1 } $node{$potentialChild}->parents;
      $children{$potentialChild}++ if exists $actualParents{$self->git_path};
    }

    return [ keys %children ];
  
  }

  #Ancestors with a mod time > than this file's mod time
  sub _build_young_ancestors {

    my $self = shift;
    my $modTime = $self->last_modified;
    my @youngAncestors;

    foreach my $ancestor ($self->ancestors) {
      my $ancestorModTime = $node{$ancestor}->last_modified;
      my $compare = DateTime->compare($ancestorModTime, $modTime);
      push(@youngAncestors, $ancestor) if $compare == 1;
    }

    return [@youngAncestors];
  }

  #Descendants with a mod time < than this file's mod time
  sub _build_old_descendants {

    my $self = shift;
    my $modTime = $self->last_modified;
    my @descendants = $self->descendants;
    my @oldDescendants;

    foreach my $descendant (@descendants) {
      next if $node{$descendant}->safe;
      my $descendantModTime = $node{$descendant}->last_modified;
      my $compare = DateTime->compare($descendantModTime, $modTime);
      push(@oldDescendants, $descendant) if $compare == -1;
    }
    return [@oldDescendants];
  }


  #Is a touch in effect?
  sub _build_touch_in_effect {
  
    my $self = shift;
    return 0 unless $self->touch;
    my $touchTime = DateTime::Format::ISO8601->parse_datetime($self->touch);
    my $modTime = $self->last_modified;
    my $touched = $touchTime == $modTime ? 1 : 0;
    return $touched;
  
  }

  #Path relative to current working directory
  sub _build_relative_path {

    my $self = shift;
    my $relativePath = File::Spec->abs2rel($gitRoot . "/" . $self->git_path);
    return $relativePath;

  }

  #Get the git modification status of a file
  sub _build_has_been_modified {

    my $self = shift;
    my $fileName = $self->relative_path;
    my $gitStatus = `git status -s $fileName`;
    my $hasBeenModified = $gitStatus eq "" ? 0 : 1;
    return $hasBeenModified;

  }

  #All ancestors of a node
  sub _build_ancestors {

    my $self = shift;
    my %ancestors;

    foreach my $parentGitPath ($self->parents) {
      my $parent = $node{$parentGitPath};
      $ancestors{$parentGitPath}++;
      $ancestors{$_}++ for $node{$parentGitPath}->ancestors;
    }

    return [ keys(%ancestors) ];

  }

  #All descendants of a node
  sub _build_descendants {

    my $self = shift;
    my %descendants;

    foreach my $childGitPath ($self->children) {
      my $child = $node{$childGitPath};
      $descendants{$childGitPath}++;
      $descendants{$_}++ for $node{$childGitPath}->children;
    }

    return [ keys(%descendants) ];
  
  }

  #Get the last modified time for a file
  #  Last modified time is defined as:
  #    If there are no local modifications to the file:
  #      Timestamp for last git commit referencing that file
  #    If there are local modifications to the file:
  #      Timestamp for last filesystem modification
  #    If the file has been touched more recently than either of
  #     these times:
  #     Use the touched time
  #
  # Returns a Date::Time object
  sub _build_last_modified {

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

    #If the file has been touched more recently than
    # modified, use the touched time
    if ($self->touch) {
      my $touchTime = DateTime::Format::ISO8601->parse_datetime($self->touch);
      $modTime = $touchTime if DateTime->compare($touchTime, $modTime) == 1;
    }

    return $modTime;

  }

  #####################
  ###               ###
  ### CLASS METHODS ###
  ###               ###
  #####################

  #Print a file, colourised by status
  sub printf { 

    my $self = shift;

    # Blue    : safed, no old descendants
    # Green   : no young ancestors, no old descendants
    # Yellow  : no young ancestors, has old descendants
    # Red     : has young ancestors

    #Blue if safed and no old descendants
    if ($self->safe and not $self->has_old_descendants) {
      print color 'blue';
      print $self->relative_path;

    #Red if there are young ancestors
    } elsif ($self->has_young_ancestors) {
      print color 'red';
      print $self->relative_path;

    #Yellow if there are old descendants but no young ancestors
    } elsif ((not $self->has_young_ancestors) and $self->has_old_descendants) {
      print color 'yellow';
      print $self->relative_path;

    #Green if there are no young ancestors and no old descendants
    } elsif ((not $self->has_young_ancestors) and (not $self->has_old_descendants)) {
      print color 'green';
      print $self->relative_path;

    #If there are reliance problems but no file modifications, something
    # has gone horribly wrong
    } else {
      die "ERROR: Something has gone horribly wrong";
    }

    #Print
    print color 'white';
    print " [";
    print "touched " if $self->touch_in_effect;
    print $self->last_modified_natural . " ago]";
    print color 'reset';
  }

  #Print reliances for a file
  sub printf_reliances {

    my $self = shift;

    #Print antecessors, if any
    my %antecessors = map { $_ => 1 } ($self->parents, $self->all_young_ancestors);
    if (keys %antecessors) {
      $self->printf;
      print " relies on:\n";
      foreach my $antecessor (keys %antecessors) {
        print "  ";
        $node{$antecessor}->printf;
        print "\n";
      }
    }

    #Print progniture, if any
    my %progeniture = map { $_ => 1 } ($self->children, $self->all_old_descendants);
    if (keys %progeniture) {
      $self->printf;
      print " is relied on by:\n";
      foreach my $progeny (keys %progeniture) {
        print "  ";
        $node{$progeny}->printf;
        print "\n";
      }
    }

  }

  #Format the last modified time, in natural language
  sub last_modified_natural {

    my $self = shift;
    my $span = DateTime::Format::Human::Duration->new();
    my $now = DateTime->now();
    my $ago = $span->format_duration_between($now, $self->last_modified, 'significant_units' => 1);
    return $ago;
  
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
  foreach my $descendant ($whither, $node{$whither}->descendants) {
    foreach my $child ($node{$descendant}->children) {
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
} elsif ($command eq 'whence') {

  #Only plot one file
  die "ERROR: 'whence' only works for a single file\n" if @fileList > 1;
  my $whence = $fileList[0];

  #Read reliances store into memory
  &read_reliances;

  #Generate list of unique edges in ancestor graph
  my %edges;
  foreach my $ancestor ($whence, $node{$whence}->ancestors) {
    foreach my $parent ($node{$ancestor}->parents) {
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
  foreach my $parent ($node{$file}->parents) {
    $edges{$node{$parent}->relative_path, $file} = [ $node{$parent}->relative_path, $file ];
  }
  foreach my $child ($node{$file}->children) {
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
  say $node{$_}->relative_path for $node{$file}->parents;

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
  say $node{$_}->relative_path for $node{$file}->children;

  #Done
  exit;

#Touch file(s) to bump the modified date
} elsif ($command eq 'touch') {

  #Read reliances store into memory
  &read_reliances;

  #Touch files
  foreach my $file (@fileList) {
    next unless exists $node{$file};
    my $now = DateTime->now()->iso8601_with_tz;
    $node{$file}->touch($now);
  }

  #Write reliances store to file
  &write_reliances;

  #Done
  say 'OK';
  exit;

#Untouch file(s)
} elsif ($command eq 'untouch') {

  #Read reliances store into memory
  &read_reliances;

  #Untouch files
  foreach my $file (@fileList) {
    $node{$file}->touch(0);
  }

  #Write reliances store to file
  &write_reliances;

  #Done
  say 'OK';
  exit;

#Check every file in the repository
} elsif ($command eq 'doctor') {

  say 'Checking all tracked files for problems...';

  #Warn if a file list was passed
  warn "Ignoring: ", join(' ', @ARGV), "\n" if @ARGV;

  #Read reliances store into memory
  &read_reliances;

  #Loop over all files
  foreach my $file (keys %node) {

    next unless $node{$file}->has_young_ancestors;
    $node{$file}->printf;
    say " relies on:";
    foreach my $youngAncestor ($node{$file}->all_young_ancestors) {
      print "  ";
      $node{$youngAncestor}->printf;
      print"\n";
    }
  
  }

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
sub validate_path {

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
    exit;
  }

  open RELIES, "<", $reliesFile;
  while (<RELIES>) {
    chomp;
    my $child = Node->new($_);
    $node{$child->git_path} = $child;
  }
  close RELIES;

  #Check that all referred nodes actually exist
  foreach my $node (values(%node)) {
    my $path = $node->relative_path;
    next if -e $path or -l $path;
    die "ERROR: tracked file $path is missing. Run `relies rm $path`, `relies mv $path <new path>`, or restore the file to continue.\n"
  }

}

#Add new reliances
sub add_parents {

  (my $child, my @parents) = @_;

  #Create nodes for child and parent files if they are new
  foreach my $gitPath (@_) {
    next if exists $node{$gitPath};
    my $newNode = Node->new( git_path => $gitPath, safe => 0, touch => 0, parents => [ ] );
    $node{$gitPath} = $newNode;
  }

  #Check for loops
  foreach my $parent (@parents) {
    my %ancestors = map { $_ => 1 } $node{$parent}->ancestors;
    next unless exists $ancestors{$child};
    die "ERROR: $child can't rely on $parent as this will create a loop\n";
  }

  #Join old and new parents
  my %parents = map { $_ => 1 } $node{$child}->parents;
  $parents{$_}++ for @parents;
  $node{$child}->parents([ keys %parents ]);

}

#Remove obsolete reliances
sub remove_parents {

  (my $child, my $bereaved) = @_;
  my %oldParents = map { $_ => 1 } $node{$child}->parents;
  delete $oldParents{$_} for @bereaved;
  $node{$child}->parents([keys %oldParents]);

}

#Write reliances to file
sub write_reliances { 

  open RELIES, ">", $reliesFile;
  foreach my $node (keys %node) {

    say RELIES join("\t", ($node{$node}->git_path, $node{$node}->safe, $node{$node}->touch, $node{$node}->parents));
  
  }
  close RELIES;

}

#Convert a passed path to a git path
sub to_git_path {

  my $filePath = shift;
  &validate_path($filePath);
  my $relativePath = File::Spec->abs2rel(abs_path_nd($filePath), $gitRoot);
  return $relativePath;

}

#Formatter to write ISO8601 timestamps
# From https://movieos.org/blog/2006/perl-datetime-iso8601/
sub DateTime::iso8601_with_tz {
  my $self = shift;
  my $val = $self->strftime('%FT%T%z');
  $val =~ s/(\d\d)$/:$1/;
  return $val;
}
