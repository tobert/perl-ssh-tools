#!/usr/bin/env perl
$|++;

###########################################################################
#                                                                         #
# Cluster Tools: cl-gatherfile.pl                                         #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

cl-gatherfile.pl - harvest files from remote systems

=head1 SYNOPSIS

 cl-gatherfile.pl [-a] -r $REMOTE_FILENAME -l $LOCAL_DIRECTORY
     -r: remote file to gather
     -l: local directory to write files to
     -a: append the hostname to the filename when writing it locally
     -d: only gather from hosts
     -n: number of hosts to gather from
     -v: verbose mode
     -h: show this help text\n

=cut

use Pod::Usage;
use File::Temp qw/tempfile/;
use File::Basename;
use Getopt::Long;
use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

our $host_cmd         = undef;
our $local_dir        = undef;
our $remote_file      = undef;
our $append_hostname  = undef;
our $help             = undef;

GetOptions(
    "l=s" => \$local_dir,
    "r=s" => \$remote_file,
    "a"   => \$append_hostname,
    "d"   => \$host_cmd,
    "h"   => \$help
);

unless ( ($local_dir && $remote_file && -r $local_dir) || $help ) {
    pod2usage();
}

unless ( -d $local_dir || mkdir($local_dir) ) {
    pod2usage( -message => "Local directory '$local_dir' does not exist and could not be created." );
}

func_loop( \&runit );

sub runit {
    my $host = shift;
    my $remote = "$remote_user\@$host:$remote_file";
    my $dest = $local_dir;

    if ( $append_hostname ) {
        my $file = basename( $remote_file );
        $dest = "$local_dir/$host-$file";
    }

    print STDERR "Command($$): /usr/bin/scp -q $ssh_options $remote $dest\n" if ( verbose() );
    system( "/usr/bin/scp -q $ssh_options $remote $dest" );
}

exit 0;

# vim: et ts=4 sw=4 ai smarttab

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2011 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
