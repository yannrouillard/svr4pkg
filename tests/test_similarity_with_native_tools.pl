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
use File::Temp;
use File::Find qw(find);
use List::Util qw(first);

use strict;
use warnings;

#############################################################################
# Useful functions
#############################################################################

##
# A set of functions to create, clean/destroy and take a
# snapshot of a temporary directoru where the test packages
# will be installed and removed
#

sub create_playground {
    my $playground_path = File::Temp->newdir();
    return ($playground_path);
}

sub clean_playground {
    my ( $playground_path, $mode ) = @_;
    my $keep_root = $mode eq 'reset' ? 0 : 1;
    remove_tree( $playground_path, { keep_root => $keep_root } );
}

my @excluded_sadm_install_files = qw(
  .door .lockfile .pkg.lock .pkg.lock.client admin logs pkglog gz-only-packages);

sub snapshot_playground {
    my ($playground_path) = @_;
    my $snapshot = {};

    # We just store the directory listing for now
    # That will be improved in the future
    my $store_sub = sub {
        my $fullname = $File::Find::name;
        my $basename = $_;
        if ( not( exists( $snapshot->{'listing'} ) ) ) {
            $snapshot->{listing} = {};
        }

        # we don't store the package spool directory
        if ( $fullname =~ m{^$playground_path/var/sadm/pkg/[^/]+/save$}x ) {
            $File::Find::prune = 1;
            return;
        }
        if ( $fullname =~ m{^$playground_path/var/sadm/install/}x
            and first { $_ eq $basename } @excluded_sadm_install_files )
        {
            if ( -d $fullname ) {
                $File::Find::prune = 1;
            }
            return;
        }
        $snapshot->{listing}{$fullname} = 1;
    };

    find( $store_sub, $playground_path );

    return ($snapshot);
}

##
# A set of functions to play some standard package operations
# individually or as part of a scenario
#
sub perform_operation {
    my ( $playground_path, $operation, $package, $mode ) = @_;

    my $device = $package;
    my $pkginst = basename( $package, '.pkg' );

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
        push( @options, '-n' );
    }
    if ( $operation eq 'install' ) {
        push( @options, ( '-d', $device ) );
    }

    system( $command, @options, $pkginst );
}

sub play_scenario {
    my ( $playground_path, $scenario, $package, $mode ) = @_;
    my $result = {};

    foreach my $action ( @{$scenario} ) {
        perform_operation( $playground_path, $action, $package, $mode );
        $result->{$action} = snapshot_playground($playground_path);
    }

    return ($result);
}

#############################################################################
# Main functions
#############################################################################

my @scenario                  = qw(install remove);
my $default_package_directory = 'tests/packages';

my %test_cases_and_packages;

if (@ARGV) {

    # If we were provided a package list of the command line
    # we will use them to run the test scenario instead
    $test_cases_and_packages{'CustomTest'} = \@ARGV;
}
else {

    opendir( my $dh, $default_package_directory );
    my @test_cases = grep { $_ !~ /^[.]{1,2}$/ } readdir($dh);
    close($dh);

    foreach my $case (@test_cases) {
        opendir( my $dh, "$default_package_directory/$case" );
        my @packages = grep { $_ !~ /^[.]{1,2}$/ } readdir($dh);
        @packages = map { "$default_package_directory/$case/$_" } @packages;
        closedir($dh);
        $test_cases_and_packages{$case} = \@packages;
    }
}

my $playground_path = create_playground();

foreach my $test_case ( keys(%test_cases_and_packages) ) {

    my $packages_list = $test_cases_and_packages{$test_case};
    foreach my $package ( @{$packages_list} ) {

        clean_playground( $playground_path, 'reset' );
        my $native_results =
          play_scenario( $playground_path, \@scenario, $package, 'native' );

        clean_playground( $playground_path, 'reset' );
        my $svr4pkg_results =
          play_scenario( $playground_path, \@scenario, $package, 'svr4pkg' );

        foreach my $action (@scenario) {
            is_deeply(
                $svr4pkg_results->{$action},
                $native_results->{$action},
                "$test_case $action " . basename($package)
            );
        }
    }
}

done_testing();
clean_playground( $playground_path, 'full' );

