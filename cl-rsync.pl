#!/usr/bin/perl
$|++;

###########################################################################
#                                                                         #
# Cluster Tools: rsync.pl                                                 #
# Copyright 2007-2010, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

rsync.pl - push files using rsync over ssh, in parallel

=head1 SYNOPSIS

 rsync.pl [-l $LOCAL_FILE] [-r $REMOTE_FILE] -b] [-t] [-d] [-a] [-n] [-x] [-h]
	-l: local file/directory to rsync - passed through unmodified to rsync
	-r: remote location for rsync to write to - also unmodified
        -x: exclude files/directories (becomes --exclude= on rsync command line)
        -n: number of hosts to run on
        -v: verbose output
        -h: print this message

=cut

use Pod::Usage;
use File::Temp qw/tempfile/;
use Getopt::Long;
use strict;
use warnings;


use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

our $local_file       = undef;
our $remote_file      = undef;
our $help             = undef;
our $exclude          = undef;
our $dryrun           = undef;
our $delete           = undef;

GetOptions(
	"l=s"  => \$local_file,
	"r=s"  => \$remote_file,
	"h"    => \$help,
	"x=s@" => \$exclude,
	"z"    => \$dryrun,
	"delete" => \$delete
);

#print "L: $local_file, R: $remote_file\n";

#if ( @ARGV == 0 or not defined $local_file or not defined $remote_file or not -r $local_file or $help ) {
#	pod2usage();
#}

if ( $delete ) {
	$delete = '--delete';
}
else {
	$delete = '';
}

if ( !$exclude ) {
	$exclude = '';
}
else {
	if ( ref $exclude eq 'ARRAY' ) {
		my @excopy = @$exclude;
		$exclude = '';
		foreach my $ex ( @excopy ) {
			$exclude .= " --exclude '$ex' ";
		}
	}
	else {
		$exclude = "--exclude '$exclude'";
	}
}

if ( $dryrun ) {
	$dryrun = ' --dry-run ';
}
else {
	$dryrun = '';
}

my $routine = sub {
	my $hostname = shift;
	if ( $dryrun ne '' ) {
		print STDERR "rsync $dryrun $delete $exclude -ave \"ssh $ssh_options\" $local_file root\@$hostname:$remote_file\n";
	}
	system( "rsync $dryrun $delete $exclude -ave \"ssh $ssh_options\" $local_file root\@$hostname:$remote_file" );
};

func_loop( $routine );

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2010 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
