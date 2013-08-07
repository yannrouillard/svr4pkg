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
use 5.010001;

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

    open(my $fh, '<', $filename) or croak("ERROR: can't open $filename");
    @array = <$fh>;
    chomp(@array);
    close($fh) or croak("ERROR: can't close $filename");

    if ( $options->{exclude} ) {
	# Let's create one big regex
	my $exclude_re = join('|', @{$options->{exclude}});
	@array = grep { $_ !~ $exclude_re } @array;
    }
    if ( $options->{sorted} ) {
        @array = sort(@array);
    }

    return (\@array);
}


sub cksum_file {
    my ($filename) = @_;
    my $cksum;

    my $cksum_output = `/usr/bin/cksum $filename 2>/dev/null`;
    $cksum = (split(/\s+/, $cksum_output, 2))[0];

    return ($cksum);
}


# We will not not compare the following files or directories
my @excluded_files_or_directory = (
    qr{/var/sadm/pkg/[^/]+/save}x,           # package spool save directory
    qr{/var/sadm/install/[.]door}x,          # various files...
    qr{/var/sadm/install/[.]lockfile}x,      # ...used by...
    qr{/var/sadm/install/[.]pkg[.]lock}x,    # ...native pkg tools...
    qr{/var/sadm/install/admin}x,            # ...that are...
    qr{/var/sadm/install/pkglog}x,           # ...not used...
    qr{/var/sadm/install/logs}x,             # ...by...
    qr{/var/sadm/install/gz-only-packages}x, # ...svr4pkg
);

# We will not compare this parameters of the pkginfo files
my @pkginfo_exclusions = (
    qr{^OAMBASE=}, # I don't know what it is
    qr{^PATH=},    # We maintain a different PATH to include our binaries
    qr{^PKGSAV},   # We don't create a package spool save directory
);

# This function store the state of the root file system used to install
# the package, taking into account some special files (pkginfo,
# /var/sadm/install/contents...) and excluding the files or directories
# not relevant.
sub snapshot_playground {
    my ( $playground_path ) = @_;
    my $snapshot = {
        'file listing'   => {},
	'file content'   => {},
	'contents file'  => [],
	'pkginfo files'  => {},
    };

    my $store_sub = sub {
        my $realpath = $File::Find::name;
	my $fullname = $realpath;
	$fullname =~ s{^$playground_path}{};
        my $basename = $_;

        # we don't store some special files or directories
	foreach my $file_pattern (@excluded_files_or_directory) {
            if ( $fullname =~ $file_pattern ) {
                # We ignore directories and don't enter them either
                if ( -d "$realpath" ) {
		    $File::Find::prune = 1;
	        }
                return;
            }
        }

	# We register the list of files, the content of files (through a simple checksum)
	# and some special files whose contents is linked to the package installation or removal
	# (e.g. pkginfo, /var/sadm/install/contents...)
        $snapshot->{'file listing'}{$fullname} = 1;
	given ($fullname) {
            when ( '/var/sadm/install/contents' ) {
                $snapshot->{'contents file'} = read_into_array($realpath, { exclude => [ qr{^#} ] });
	    }
	    when ( qr{/var/sadm/pkg/([^/]+)/pkginfo}x ) {
                $snapshot->{'pkginfo files'}{$1} = read_into_array($realpath, { sorted => 1, exclude => \@pkginfo_exclusions });
	    }
            default {
                if ( -f "$realpath" ) {
		    $snapshot->{'file content'}{$fullname} = cksum_file($fullname);
		}
	    }
	}
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

    system( $command, @options, $pkginst );
}

# Play the given scenario
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

    # Otherwise we just use the packages in the $default_package_directory
    # The structure is:
    # Each sub-directory is named after the kind of packages it contains
    # e.g:  $default_package_directory/SimplePackage/Package1.pkg
    opendir( my $dh, $default_package_directory );
    my @test_cases = grep { $_ !~ /^[.]{1,2}$/ } readdir($dh);
    closedir($dh);

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

        # Foreach package we play the list of actions specified in scenario,
	# First we the native tools then with svr4pkg
	# We register the state of the root system after each and we compare
	# them after

        clean_playground( $playground_path, 'reset' );
        my $native_results = play_scenario( $playground_path, \@scenario, $package, 'native' );

        clean_playground( $playground_path, 'reset' );
        my $svr4pkg_results = play_scenario( $playground_path, \@scenario, $package, 'svr4pkg' );

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

