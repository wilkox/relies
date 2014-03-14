#!/usr/bin/perl

use Modern::Perl 2013;
use Tree::DAG_Node;
use autodie;
$|++;

#Look for .relies in the git respository root
my $DotReliesPath;
my $GitRoot = `git rev-parse --show-toplevel`;
chomp $GitRoot;
say "Git root is $GitRoot";
