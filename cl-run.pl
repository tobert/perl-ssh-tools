#!/usr/bin/perl
$|++;

###########################################################################
#                                                                         #
# Cluster Tools: cl-run.pl                                                #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

cl-run.pl - run commands in parallel across the cluster

=head1 SYNOPSIS

This script parallelizes ssh access to hosts.

 cl-run.pl -s $SCRIPT    [-l $FILE] [-r $FILE] [-e $FILE] [-b] [-t] [-d] [-a] [-n] [-h]
 cl-run.pl -c '$COMMAND' [-l $FILE] [-r $FILE] [-e $FILE] [-b] [-t] [-d] [-a] [-n] [-h]
        -s: script/program to copy out then run
        -c: command to run on each host
                - this will be written to a mini shell script then pushed out
        -l: place to write program output locally
        -r: place to write program output on the remote hosts
                - this only creates a shell variable in the command scripts that can
                  be redirected to using \$output
        -e: file to write errors to
        -b: background the jobs on the remote host
                - equivalent to \"nohup command &\"
        -t: when writing to a local file with -l, prepend the source hostname to every
                line of output
        -n: number of hosts to run on
        -h: print this message

=cut

use strict;
use warnings;
use Pod::Usage;
use Getopt::Long;
use File::Copy qw( copy );
use File::Temp qw/tempfile/;
use Fcntl ':flock';
use IO::Handle;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

select(STDERR);

our $errfile          = "&1";
our $slaves           = undef;
our $tag_local_output = undef;
our $local_output     = undef;
our $remote_output    = undef;
our $background       = undef;
our $command          = undef;
our $script           = undef;
our $help             = undef;

GetOptions(
	"s=s" => \$script,
	"c=s" => \$command,
	"l=s" => \$local_output,
	"r=s" => \$remote_output,
	"e=s" => \$errfile,
	"b"   => \$background,
	"n:i" => \$slaves,
	"h"   => \$help
);

$tag_local_output = tag_output();

if ( $help || (!$command && !$script) ) {
	pod2usage();
}

if ( $script && $command ) {
	pod2usage( -message => "-s and -c are mutually exclusive" );
}

my( $fh, $cmdfile ) = tempfile();
if ( $command ) {
	print $fh "#!/bin/bash\n";
	print $fh "cd /var/tmp\n";
	if ( $remote_output ) {
		print $fh "outfile=$remote_output\n";
	}
	else {
		print $fh "outfile=/tmp/`hostname`.output\n";
	}
	print $fh "rm -f \$outfile\n";
	if ( $background ) {
		print $fh "nohup $command &\n";
	}
	else {
		print $fh "$command\n";
	}
	print $fh "rm -f $cmdfile\n";
	close $fh;
}
else {
	close $fh;
	copy( $script, $cmdfile );
	chmod( 0755, $cmdfile );
}

func_loop( \&runit );

sub runit {
	my $host = shift;

    system( "/usr/bin/scp -q $ssh_options $cmdfile $host:$cmdfile" );

	print STDERR "$host: /bin/bash $cmdfile\n" if ( verbose() );

	#my @out = `/usr/bin/ssh $ssh_options $host /bin/bash $cmdfile`;
    my @out = ssh( $host, "/bin/bash $cmdfile" );
	my $fh;
	if ( $local_output ) {
		open( $fh, ">> $local_output" );
		flock( $fh, LOCK_EX );
		seek( $fh, 0, 2 );
	}
	else {
		$fh = IO::Handle->new_from_fd( fileno(STDOUT), 'w' );
	}

	if ( $tag_local_output ) {
		for my $line ( @out ) {
			print $fh "$host: $line\n";
		}
	}
	else {
		print $fh join("\n",@out), "\n";
	}

	flock( $fh, LOCK_UN ) if ( $local_output );
	close $fh;

	exit 0;
}

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2011 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
