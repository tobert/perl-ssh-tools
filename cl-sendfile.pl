#!/usr/bin/env perl
$|++;

###########################################################################
#                                                                         #
# Cluster Tools: cl-sendfile.pl                                           #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

cl-sendfile.pl - push a file over scp, in parallel

=head1 SYNOPSIS

Send files to cluster nodes.   This also archives those files in the /root/files to make tracking changes to the cluster
from default installs easier.

 cl-sendfile.pl -a -l /etc/httpd/conf/httpd.conf
 cl-sendfile.pl -d -l /tmp/foo.conf -r /usr/local/etc/foo.conf

 cl-sendfile.pl [-l $LOCAL_FILE] [-r $REMOTE_FILE] [-h] [-v] [--incl <pattern>] [--excl <pattern>]
        -l: local file/directory to rsync - passed through unmodified to rsync
        -r: remote location for rsync to write to - also unmodified
        -x: stage the file as a normal user and relocate using sudo (requires sudo root/NOPASSWD)
        -v: verbose output
        -h: print this message
=cut

use Pod::Usage;
use File::Temp qw/tempfile/;
use File::Basename;
use File::Copy;
use Getopt::Long;
use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

our $local_file       = undef;
our $remote_file      = undef;
our $help             = undef;
our $sudo             = undef;
our $final_file       = undef;

GetOptions(
    "l=s" => \$local_file,
    "r=s" => \$remote_file,
    "x"   => \$sudo,
    "h"   => \$help
);

if ( !$remote_file && $local_file && $local_file =~ m#^/# ) {
    $remote_file = $local_file;
}

unless ( ($local_file && $remote_file && -r $local_file) || $help ) {
    pod2usage();
}

$final_file = $remote_file;
if ( $sudo ) {
    (my $fh, $remote_file) = my_tempfile();
    close $fh;
    unlink $remote_file;
}

func_loop(sub {
    my $host = shift;
    scp( $local_file, "$host:$remote_file" );
});

if ( $sudo ) {
    func_loop(sub {
        my $host = shift;
        ssh( "$remote_user\@$host", "sudo cp $remote_file $final_file" );
        ssh( "$remote_user\@$host", "rm $remote_file" );
    });
}

# vim: et ts=4 sw=4 ai smarttab

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2011 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
