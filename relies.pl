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
my $gitRoot = `git rev-parse --show-toplevel` or die "";
chomp $gitRoot;

my $reliesFile = $gitRoot . "/.relies";

#Store for Node objects
# Key: passed path
# Value: obj
my %node;

#Parse command line options
my @parents;
my @bereaved;
my @children;
my $full;
my @safe;
my @unsafe;
my $whither;
my $whence;
my $precommit;

GetOptions (

  #Passed files
  "on=s{,}" => \@parents,
  "off=s{,}" => \@bereaved,
  "safe=s{,}" => \@safe,
  "unsafe=s{,}" => \@unsafe,
  "whither|descendants=s" => \$whither,
  "whence|ancestors=s" => \$whence,

  #Flags
  "full" => \$full,

  #Git pre-commit hook
  "precommit" => \$precommit
);

#Mop any remaining arguments into @children
@children = @ARGV;

#If we are using a mode requiring children,
# and no children given, or './' or '.' given, 
# glob the current directory as children
if ((@children == 0 or $children[0] eq '.' or $children[0] eq './') and not $whither and not $whence and not $precommit) {
  @children = glob('./*');
  @children = grep { !-d $_ } @children;
}

#Validate passed files and convert to git paths
@children = map { &to_git_path($_) } (@children);
@parents = map { &to_git_path($_) } (@parents);
@bereaved = map { &to_git_path($_) } (@bereaved);
@safe = map { &to_git_path($_) } (@safe);
@unsafe = map { &to_git_path($_) } (@unsafe);
$whither = &to_git_path($whither) if $whither;
$whence = &to_git_path($whence) if $whence;

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

    print $self->relative_path;
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

#Git pre-commit hook
if ($precommit) {

  system("touch ~/it_happened");

#Safeing
} elsif (@safe || @unsafe) {

  #Incompatible options
  die "ERROR: Slow down, tiger...one thing at a time" if @parents || @bereaved || $whither || $whence || $precommit;
  warn "WARNING: ignoring $_\n" for @children;
  warn "WARNING: ignoring --full\n" if $full;

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

  #Incompatible options
  die "ERROR: Slow down, tiger...one thing at a time" if @safe || @unsafe || $whither || $whence || $precommit;
  warn "WARNING: ignoring --full\n" if $full;

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

#Graph descendants
} elsif ($whither) {

  #Incompatible options
  die "ERROR: Slow down, tiger...one thing at a time" if @safe || @unsafe || @parents || @bereaved || $whence || $precommit;
  warn "WARNING: ignoring $_\n" for @children;
  warn "WARNING: ignoring --full\n" if $full;

  #Read reliances store into memory
  &read_reliances;

  #Generate list of unique edges in descendant graph
  my %edges;
  foreach my $descendant ($whither, @{$node{$whither}->descendants}) {
    foreach my $child (@{$node{$descendant}->children}) {
      $edges{$descendant, $child} = [ $descendant, $child ];
    }
  }

  if (keys %edges == 0) {
    say "$whither has no descendants";
    exit;
  }

  #Construct Graph::Easy graph
  my $graph = Graph::Easy->new();
  $graph->add_edge(@{$_}[0], @{$_}[1]) for values %edges;

  print $graph->as_boxart();

  #Done
  exit;

#Graph ancestors
} elsif ($whence) {

  #Incompatible options
  die "ERROR: Slow down, tiger...one thing at a time" if @safe || @unsafe || @parents || @bereaved || $whither || $precommit;
  warn "WARNING: ignoring $_\n" for @children;
  warn "WARNING: ignoring --full\n" if $full;

  #Read reliances store into memory
  &read_reliances;

  #Generate list of unique edges in ancestor graph
  my %edges;
  foreach my $ancestor ($whence, @{$node{$whence}->ancestors}) {
    foreach my $parent (@{$node{$ancestor}->parents}) {
      $edges{$ancestor, $parent} = [ $ancestor, $parent ];
    }
  }

  if (keys %edges == 0) {
    say "$whence has no ancestors";
    exit;
  }

  #Construct Graph::Easy graph
  my $graph = Graph::Easy->new();
  $graph->add_edge(@{$_}[1], @{$_}[0]) for values %edges;

  print $graph->as_boxart();

  #Done
  exit;

#If no options were provided, give information about
# the listed child(ren)
} else {

  #Read reliances store into memory
  &read_reliances;

  #Describe parents for children
  $node{$_}->printf_reliances for @children;

  #Done
  exit;

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
    my $newNode = Node->new( git_path => $gitPath, safe => 0, parents => [ ]);
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

#Convert a passed path to a git path
sub to_git_path {

  my $filePath = shift;
  &validate_file($filePath);
  my $relativePath = File::Spec->abs2rel(abs_path_nd($filePath), $gitRoot);
  return $relativePath;

}
