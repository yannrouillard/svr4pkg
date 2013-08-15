#!/usr/bin/env perl
# Test script to ensure svr4pkg behaves more or less like the native
# solaris SVR4 package commands
#
# Copyright (C) 2013 Yann Rouillard <yann@pleides.fr.eu.org>

# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA.
#

# This test script is supposed to be run on a Solaris server where the
# pkginfo, pkgadd, pkgrm... tools are installed.
# It will create a safe playground under /tmp to fake package installations,
# removals and so on.

use Test::More;
use File::Basename qw(basename);
use File::Path qw(remove_tree);
use File::Spec::Functions qw(catfile);
use File::Temp;
use File::Find qw(find);
use List::Util qw(first);
use Carp qw(croak);
use 5.010001;

use strict;
use warnings;

#############################################################################
# Useful functions
#############################################################################

#############################################################################
# A set of functions to create, clean/destroy and take a
# snapshot of a temporary directoru where the test packages
# will be installed and removed
#

# Create a temporary directory to use as a root file system
sub create_playground {
    my $playground_path = File::Temp->newdir();
    return ($playground_path);
}

# Clean the temporary directory either entirely ('full' mode)
# or only the subfiles and directories ('reset' mode)
sub clean_playground {
    my ( $playground_path, $mode ) = @_;
    my $keep_root = $mode eq 'reset' ? 1 : 0;
    remove_tree( $playground_path, { keep_root => $keep_root } );
}

# Put the content of the given file into an array
# The returned array can be sorted (options 'sorted' => 1)
# and it can be filtered
# (options 'excluded' => [ list of regexes to exclude ])
sub read_into_array {
    my ( $filename, $options ) = @_;
    my @array;

    open( my $fh, '<', $filename ) or croak("ERROR: can't open $filename");
    @array = <$fh>;
    chomp(@array);
    close($fh) or croak("ERROR: can't close $filename");

    if ( $options->{exclude} ) {

        # Let's create one big regex
        my $exclude_re = join( '|', @{ $options->{exclude} } );
        @array = grep { $_ !~ $exclude_re } @array;
    }
    if ( $options->{sorted} ) {
        @array = sort(@array);
    }

    return ( \@array );
}

sub cksum_file {
    my ($filename) = @_;
    my $cksum;

    my $cksum_output = `/usr/bin/cksum $filename 2>/dev/null`;
    $cksum = ( split( /\s+/, $cksum_output, 2 ) )[0];

    return ($cksum);
}

# We will not not compare the following files or directories
my @excluded_files_or_directory = (
    qr{/var/sadm/pkg/[^/]+/save}x,              # package spool save directory
    qr{/var/sadm/install/[.]door}x,             # various files...
    qr{/var/sadm/install/[.]lockfile}x,         # ...used by...
    qr{/var/sadm/install/[.]pkg[.]lock}x,       # ...native pkg tools...
    qr{/var/sadm/install/admin}x,               # ...that are...
    qr{/var/sadm/install/pkglog}x,              # ...not used...
    qr{/var/sadm/install/logs}x,                # ...by...
    qr{/var/sadm/install/gz-only-packages}x,    # ...svr4pkg
    qr{/usr/sadm$}x,
    qr{/usr$}x,
);

my %path_mappings = ( '/usr/sadm/install' => '/var/sadm/install', );

# We will not compare this parameters of the pkginfo files
my @pkginfo_exclusions = (
    qr{^OAMBASE=},    # I don't know what it is
    qr{^PATH=},       # We maintain a different PATH to include our binaries
    qr{^PKGSAV},      # We don't create a package spool save directory
);

#############################################################################
# This function store the state of the root file system used to install
# the package, taking into account some special files (pkginfo,
# /var/sadm/install/contents...) and excluding the files or directories
# not relevant.

sub snapshot_playground {
    my ($playground_path) = @_;
    my $snapshot = {
        'file listing'  => {},
        'file content'  => {},
        'contents file' => [],
        'pkginfo files' => {},
    };

    my $store_sub = sub {
        my $realpath = $File::Find::name;
        my $fullname = $realpath;
        $fullname =~ s{^$playground_path}{};
        my $basename = $_;

        # Some files are special and deserve a special treatment
        # (e.g. pkginfo, /var/sadm/install/contents...)
        if ( $fullname eq '/var/sadm/install/contents' ) {
            $snapshot->{'contents file'} =
              read_into_array( $realpath, { exclude => [qr{^#}] } );
            return;
        }
        if ( $fullname =~ qr{/var/sadm/pkg/([^/]+)/pkginfo}x ) {
            $snapshot->{'pkginfo files'}{$1} =
              read_into_array( $realpath,
                { sorted => 1, exclude => \@pkginfo_exclusions } );
            return;
        }

        # we exclude from the comparison some files or directories that will
        # always be different
        foreach my $file_pattern (@excluded_files_or_directory) {
            return if ( $fullname =~ $file_pattern );
        }

   # We transform some path that are always different between native and svr4pkg
        foreach my $path ( keys(%path_mappings) ) {
            my $new_path = $path_mappings{$path};
            $fullname =~ s/^$path/$new_path/;
        }

# We register the list of files, the content of files (through a simple checksum)
        $snapshot->{'file listing'}{$fullname} = 1;
        if ( -f "$realpath" ) {
            $snapshot->{'file content'}{$fullname} = cksum_file($realpath);
        }
    };

    find( $store_sub, $playground_path );

    return ($snapshot);
}

#############################################################################
# A set of functions to play some standard package operations
# individually or as part of a scenario
#
sub perform_operation {
    my ( $playground_path, $operation, $package, $mode ) = @_;

    my $device = $package;
    my $pkginst = basename( $package, '.pkg' );
    $pkginst =~ s/\d+-//;

    my $command;
    my @options;

    my $pkg_operation = $operation eq 'install' ? 'add' : 'rm';
    if ( $mode eq 'native' ) {
        $command = "pkg$pkg_operation";
    }
    else {
        $command = './svr4pkg';
        push( @options, $pkg_operation );
    }

    push( @options, ( '-R', $playground_path ) );

    if ( $mode eq 'native' ) {

        # Quiet mode
        push( @options, '-n' );
    }
    if ( $operation eq 'install' ) {
        push( @options, ( '-d', $device ) );
    }

    # This environnement variable tells the pkgserver that it musts
    # quit after. Otherwise the /var/sadm/install/contents is not
    # always updated after package installation or removal
    local $ENV{SUNW_PKG_SERVERMODE} = 'run_once';

    my $full_command = join( ' ', ( $command, @options, $pkginst ) );
    system("$full_command >/dev/null 2>&1");
}

# Play the given scenario
sub play_scenario {
    my ( $scenario, $mode, $playground_path, $packages_path ) = @_;
    my $result;

    foreach
      my $step ( @{ $scenario->{prerequisites} }, @{ $scenario->{steps} } )
    {
        my $package = catfile( $packages_path, $step->{package} );
        perform_operation( $playground_path, $step->{action}, $package, $mode );
    }

    given ( $scenario->{test} ) {
        when ('filesystem') { $result = snapshot_playground($playground_path); }
        default             { $result = undef; }
    }

    return ($result);
}

# Parse a string of text contains the textual description
# of a scenario and returns it as a list of steps to perform
# The line should have the form "action1 package1 action2 package2..."
sub parse_scenario_steps {
    my ($steps_description) = @_;
    my @scenario_steps;

    my @items = ( $steps_description =~ m{(?:(\S+)\s+(\S+))}g );
    return if ( not @items );

    foreach my $index ( 0 .. @items / 2 - 1 ) {
        push(
            @scenario_steps,
            {
                'action'  => $items[ 2 * $index ],
                'package' => $items[ 2 * $index + 1 ]
            }
        );
    }

    return ( \@scenario_steps );
}

# Parse the text file containing the list of scenario to test
# and returns the content in a structured form
#
# Each line should have the form:
#   Name of test | scenario | test | prerequisites
#
#  - scenario is a list of action to perform on package
#    (see parse_scenario_steps)
#  - test is a kind of comparison to be perform between native
#    and svr4pkg at the end of the scenario
#  - prerequisites can be a list of action to perform on package
#    like scenario, or it can be the name of a previous scenario
#
sub parse_test_scenarios {
    my ($scenario_file) = @_;
    my @test_scenarios;

    open( my $fh, '<', $scenario_file )
      or croak("Can't open file $scenario_file !\n");
    while ( my $line = <$fh> ) {
        chomp($line);
        next if ( $line =~ /^(#|\s*$)/ );

        my (
            $test_name,       $scenario_description,
            $comparison_test, $prerequisites
        ) = split( /\s*[|]\s*/, $line );
        return if not defined($comparison_test);

        my $scenario_steps = parse_scenario_steps($scenario_description);
        return if not defined($scenario_steps);

        my $prerequisites_steps = [];
        if ( defined($prerequisites) and $prerequisites ne '' ) {

            # We check wether the prerequisites are a reference to a previous scenario
            if ( my $scenario =
                first { $_->{name} eq $prerequisites } @test_scenarios )
            {
                @{$prerequisites_steps} =
                    ( @{ $scenario->{prerequisites} }, @{ $scenario->{steps} } );
            }
            else {
                $prerequisites_steps = parse_scenario_steps($prerequisites);
            }
        }

        push(
            @test_scenarios,
            {
                name          => $test_name,
                steps         => $scenario_steps,
                test          => $comparison_test,
                prerequisites => $prerequisites_steps,
            }
        );
    }
    close($fh) or croak("Can't close file $scenario_file !\n");

    return ( \@test_scenarios );
}

#############################################################################
# Main program
#############################################################################

my $scenarios_file = 'tests/scenarios.txt';
my $packages_path  = 'tests/packages';

my $playground_path = create_playground();

my $test_scenarios = parse_test_scenarios($scenarios_file);
foreach my $scenario ( @{$test_scenarios} ) {

    # We play each scenario first with the native tools then with svr4pkg
    # then we will compare the results of the two runs

    clean_playground( $playground_path, 'reset' );
    my $native_results =
      play_scenario( $scenario, 'native', $playground_path, $packages_path );

    clean_playground( $playground_path, 'reset' );
    my $svr4pkg_results =
      play_scenario( $scenario, 'svr4pkg', $playground_path, $packages_path );

    is_deeply( $svr4pkg_results, $native_results, $scenario->{name} );
}
done_testing();

clean_playground( $playground_path, 'full' );

