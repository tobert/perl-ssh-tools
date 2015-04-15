package DshPerlHostLoop;

###########################################################################
#                                                                         #
# Cluster Tools: DshPerlHostLoop.pm                                       #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

use strict;
use warnings;
use Carp;
use File::Basename;
use Data::Dumper;
use IPC::Open3;
use IO::Select;
use IO::Handle;
use Sys::Hostname ();
use Fcntl ':flock';
use File::Temp qw(tempfile);
use Tie::IxHash;
eval { use Net::SSH2; }; # optional
use base 'Exporter';

# globals!
our @opt_filter_excl;
our @opt_filter_incl;
our $opt_batch;
our $ssh_options .= " -o 'BatchMode yes' -o 'StrictHostKeyChecking no' -o 'ConnectTimeout 10'";
our $tag_output = 1;
our $debug = undef;
our $verbose;
our $tempdir = '/var/tmp';
our $mainpid = $$;
our $machines_list ||= "$ENV{HOME}/.dsh/machines.list"; # can be overridden with --list $name
our @tempfiles;
our $remote_user ||= $ENV{USER};
our $sshkey ||= "$ENV{HOME}/.ssh/id_rsa";
our $retry_wait = 30;
our $lock_fh = tempfile();
our $hostname_pad = 8;

# Most shops have a noisy /etc/issue.net. This reads the local issue.net
# and removes any lines matching it from the output from ssh.
my @issue = read_issue();
my $issue_len = length(join("\n", @issue));

use constant BLACK   => "\x1b[30m";
use constant RED     => "\x1b[31m";
use constant GREEN   => "\x1b[32m";
use constant YELLOW  => "\x1b[33m";
use constant BLUE    => "\x1b[34m";
use constant MAGENTA => "\x1b[35m";
use constant CYAN    => "\x1b[36m";
use constant WHITE   => "\x1b[37m";
use constant DKGRAY  => "\x1b[1;30m";
use constant DKRED   => "\x1b[1;31m";
use constant RESET   => "\x1b[0m";

# please, for the love of FSM, do not copy the style of this module
# @EXPORT is the kind of thing that makes sense when you quickly turn
# a utility (in this case, cl-run.pl's predecessor) into a module so
# you can whip up a bunch of look-alike utilities. The right thing to
# do from the start is to design a clean module, at least using
# class methods so their origin is clearly visible in downstream source.
# It's on my TODO list ;)
our @EXPORT = qw(
  func_loop ssh scp hostlist reap verbose my_tempfile tag_output
  libssh2_connect libssh2_reconnect libssh2_slurp_cmd
  $ssh_options $remote_user $retry_wait $hostname_pad
  @opt_filter_excl @opt_filter_incl $opt_batch
  lock unlock
  BLACK RED GREEN YELLOW BLUE MAGENTA CYAN WHITE DKGRAY DKRED RESET
);

=head1 NAME

DshPerlHostLoop - loops for running ssh commands across large clusters in parallel

=head1 SYNOPSIS

 use FindBin qw($Bin);
 require "$Bin/DshPerlHostLoop.pm";

 func_loop( sub { system( "ssh $_[1] uname -a" ); } );

=head1 GLOBAL SWITCHES

A few global CLI switches are implemented in this module in a BEGIN block.

 --incl - a perl regular expression that filters out non-matching hostnames
 --excl - a perl regular expression that filters matched hostnames out of the list
 --batch - run in parallel on every N nodes, shifting by 1 until all are complete
 --list - name of the list, e.g. ~/.dsh/machines.$NAME
 --root - set remote user to root
 --user - set the remote username to something other than $USER or root
 -u     - don't prefix output with the remote hostname
 -v     - verbose
 -m     - specify a file with a list of hosts to use (default is ~/.dsh/machines.list)

--excl RE's are run before --incl RE's.

=head1 FUNCTIONS

=over 4

=item func_loop()

Execute a callback in parallel for each host.   The first argument passed to each callback will be the hostname.

 # hello, cruel world
 func_loop( sub { print "$@\n"; } );

=cut

sub func_loop {
    my $f = shift;

    if ( ref($f) ne 'CODE' ) {
        confess "Argument to DshPerlHostLoop must be a subroutine/closure.";
    }

    my %pids;
    tie my %hosts, 'Tie::IxHash';
    %hosts = hostlist(keep_comments => 1);
    my @hostnames = keys %hosts;

    # support batched commands in increments of $opt_batch
    # This is useful for large clusters where doing the whole cluster at once
    # is a bad idea. Set --batch 1 for serial execution.
    my @batches = ();
    $opt_batch ||= 0;
    if ($opt_batch > 0) {
        my $batch_count = scalar(@hostnames) / $opt_batch;

        for (my $b=0; $b<$batch_count; $b++) {
            for (my $h=0; $h<$opt_batch; $h++) {
                my $host = shift(@hostnames);
                push @{$batches[$b]}, $host;
            }
        }
    }
    # default to one batch of all hosts
    else {
      @batches = (\@hostnames);
    }

    foreach my $batch (@batches) {
        foreach my $hostname (@{$batch}) {
            my $pid = fork();
            if ( $pid ) {
                $pids{$hostname} = $pid;
                next;
            }
            else {
                eval { $0 = "$0 -- $hostname"; };
                my @out = eval { $f->( $hostname, $hosts{$hostname} ); };
                if ( $@ ) {
                    confess $@;
                }

                exit 0;
            }
        }

        # should block until all commands exit
        reap( \%pids );
    }
}

=item read_issue()

Read /etc/issue.net or if that doesn't exist, /etc/issue.   This is used to filter out
issues from remote systems to keep your output readable.

Returns an array of chomped lines.

=cut

sub read_issue {
    my @issue;
    my $fh;
    if ( -r '/etc/issue.net' ) {
        open( my $fh, "< /etc/issue.net" ) or $fh = undef;
    }
    elsif ( -r '/etc/issue' ) {
        open( my $fh, "< /etc/issue" ) or $fh = undef;
    }
    if ( $fh ) {
        while ( my $line = <$fh> ) {
            chomp $line;
            push @issue, $line;
        }
        close $fh;
    }
    return @issue;
}

=item ssh()

Run a command over ssh.

 func_loop(sub {
     my $host = shift;
     ssh( $host, 'ps -ef' );
 });

=item scp()

scp a file.

 my($local_file, $remote_file) = ("/etc/hosts", "/etc/hosts");
 func_loop(sub {
     my $host = shift;
     scp( $local_file, "$host:$remote_file" );
 });

=item scmd()

The actual function behind ssh/scp.

 sub ssh { scmd('/usr/bin/ssh', @_) }
 sub scp { scmd('/usr/bin/scp', '-v', @_) }

=cut

# archaic & insecure but fast and convenient
# in other words, don't let untrusted people sudo this!!
sub ssh { scmd('/usr/bin/ssh', '-o', "'User $remote_user'", @_) }
sub scp { scmd('/usr/bin/scp', '-o', "'User $remote_user'", '-v', @_) }
sub scmd {
    my $scmd = shift;

    my @output;
    my( $in, $out, $err ) = (IO::Handle->new, IO::Handle->new, IO::Handle->new);
    my $pid = open3( $in, $out, $err, "$scmd $ssh_options @_" );

    if ( $verbose ) {
        print STDERR "Command($$): $scmd $ssh_options @_\n";
    }

    my $select = IO::Select->new( $out, $err );
    my $ofd = fileno($out);
    my $efd = fileno($err);

    my %eofs;

    my $bytes = 0;
    SELECT: while ( my @ready = $select->can_read(10) ) {
        READY: foreach my $r ( @ready ) {
            my $rfd = fileno($r);

            if ( exists($eofs{$rfd}) ) {
                $select->remove($rfd);
                next SELECT;
            }
            elsif ( $rfd == $ofd ) {
                my $line = <$out>;
                chomp $line if ( $line );
                $bytes += length($line) if ( $line );
                push @output, $line if ( $line );

                $eofs{$rfd} = 1 if ( eof($out) );
            }
            elsif ( $rfd == $efd ) {
                my $line = <$err>;
                chomp $line if ( $line );
                # don't look for issue.net matches after its byte size has past
                unless ( !$line or ($bytes < $issue_len and grep { $_ eq $line } @issue) ) {
                    $bytes += length($line) if ( $line );
                    # TODO: probably should detect a terminal or have an option to disable color
                    push @output, RED . $line . RESET;
                }
                $eofs{$rfd} = 1 if ( eof($err) );
            }
            else {
                warn "Got read error on $rfd ...";
            }

        }
    }

    # this usually means success
    if ( $bytes == 0 ) {
        push @output, "''";
        printf STDERR "%sGot zero bytes from command: $scmd @_%s\n", CYAN, RESET if ($verbose);
    }

    waitpid( $pid, 0 );
    if ( $? != 0 ) {
        printf STDERR "%sGot non-zero exit status from command: $scmd @_%s\n", RED, RESET;
    }

    return @output;
}

=item libssh2_connect()

Connect to the remote host over SSH using Net::SSH2 instead
of shelling out. This is a bit more efficient over the long run,
but does not work with ssh agent, and therefore doesn't work
with encrypted ssh keys.

=cut

# sets up the ssh2 connection
sub libssh2_connect {
    my( $hostname, $port, $bundle ) = @_;
    $port ||= 22;

    # TODO: make this configurable
    my @keys = (
        # my monitor-rsa key is unencrypted to work with Net::SSH2
        # it is restricted to '/bin/cat /proc/net/dev etc.' though so very low risk
        [
            $remote_user,
            $ENV{HOME}.'/.ssh/monitor-rsa.pub',
            $ENV{HOME}.'/.ssh/monitor-rsa'
        ],
        [
            $remote_user,
            $sshkey . '.pub', # this should usually be correct
            $sshkey           # settable on the CLI with -i
        ]
    );

    my $ssh2 = Net::SSH2->new();
    my $ok;

    for (my $i=0; $i<@keys; $i++) {
        $ssh2->connect( $hostname, $port, Timeout => 3 );

        $ok = $ssh2->auth_agent( $remote_user );
        last if ($ok);

        $ok = $ssh2->auth_publickey( @{$keys[$i]} );
        last if ($ok);

        printf STDERR "%sFailed authentication as user %s with pubkey %s, trying %s:%s%s\n",
            RED, $keys[0]->[0], $keys[0]->[1], $keys[1]->[0], $keys[1]->[1], RESET;
    }
    $ok or die "Could not authenticate.";

    if ($ssh2) {
        if ($bundle) {
            $bundle->host($hostname);
            $bundle->port($port);
            $bundle->ssh2($ssh2);
        }
        else {
            $bundle = bless {
                host => $hostname,
                port => $port,
                ssh2 => $ssh2
            }, 'DshPerlHostLoop::Bundle';
        }
    }
    else {
        $bundle->ssh2(undef);
        $bundle->last_attempt(time);
    }

    return $bundle;
}

sub libssh2_reconnect {
    my $bundle = shift;

    # on connection failures, wait a minute and try again until it works
    if (not defined $bundle->ssh2) {
        if ($bundle->next_attempt < time) {
            printf "%sretrying connection to %s ...", BLUE, $bundle->host;
            eval {
                libssh2_connect( $bundle->host, $bundle->port, $bundle );
            };
            if ($@) {
                print RED, "FAILED. Trying again in $retry_wait seconds.\n";

                $bundle->ssh2(undef);
                $bundle->next_attempt(time + $retry_wait);
                $bundle->retries($bundle->retries + 1);

                return undef;
            }
            else {
                $bundle->retries(0);
                print GREEN, "SUCCESS!\n";
            }
        }
        else {
            return;
        }
    }

    return $bundle;
}

=item libssh2_slurp_cmd()

Run a command over an existing libssh2 connection and capture all
of its output.

 my $input = libssh2_slurp_cmd( $ssh2, $command );

=cut

sub libssh2_slurp_cmd {
    my( $bundle, $cmd ) = @_;

    libssh2_reconnect( $bundle ) unless ( ref $bundle && $bundle->ssh2 );
    unless ($bundle && $bundle->ssh2) {
        return undef;
    }

    my $data = '';
    eval {
        my $chan = $bundle->ssh2->channel();
        $chan->exec( $cmd );

        while ( !$chan->eof() ) {
            $chan->read( my $buffer, 4096 );
            $data .= $buffer;
        }

        $chan->close();
    };
    if ( $@ ) {
        $bundle->ssh2(undef);
        $bundle->next_attempt(time + $retry_wait);
        $bundle->retries(0);
        return undef;
    }
    else {
        return [split(/[\r\n]+/, $data)];
    }
}

=item hostlist()

Returns an array of hosts to be accessed.  This reads the hostname list (-m $file or default ~/.dsh/machines.list)
then filters it based on --excl and --incl regular expressions. 

 my @hosts = hostlist();

 # use Tie::IxHash to preserve insertion order if desired
 tie my %hosts_and_comments, 'Tie::IxHash';
 %hosts_and_comments = hostlist(want_comments => 1);

=cut

sub hostlist {
    my %options = @_;

    my @hostlist;
    open( my $fh, "< $machines_list" )
        or die "Could not open machine list file '$machines_list' for reading: $!";

    HOST: while ( my $line = <$fh> ) {
        chomp $line;
        next unless ( $line && length $line );
        next if ( $line =~ /^\s*#/ );

        my($hostname, $comment) = split( /\s*#\s*/, $line, 2 );

        $hostname =~ s/\s//g;
        $comment ||= '';
        $comment =~ s/^\s+//;
        $comment =~ s/\s+$//;

        next unless ( length $hostname );

        FILTER_EX: foreach my $excl ( @opt_filter_excl ) {
            if ( $hostname =~ /$excl/ ) {
                printf "%sDshPerlHostLoop: Skipping $hostname because it matched filter $excl.%s\n", BLUE, RESET if ( $debug );
                next HOST;
            }
        }
        FILTER_IN: foreach my $incl ( @opt_filter_incl ) {
            if ( $hostname !~ /$incl/i ) {
                print "%sDshPerlHostLoop: Skipping $hostname because it didn't match filter $incl.%s\n", BLUE, RESET if ( $debug );
                next HOST;
            }
        }

        # update the global hostname padding variable used for pretty printing
        if (length($hostname) + 2 > $hostname_pad) {
            $hostname_pad = length($hostname) + 2;
        }

        if ($options{keep_comments}) {
            push @hostlist, $hostname, $comment;
        }
        else {
            push @hostlist, $hostname;
        }
    }

    close $fh;

    return @hostlist;
}

=item reap()

Reap child processes from the forkbomb. The hash is { $hostname => $pid }.

 reap(\%pids);

=cut

sub reap {
    my $pids = shift;
    foreach my $host ( keys %$pids ) {
        waitpid( $pids->{$host}, 0 );
        delete $pids->{$host};
    }
}

=item tag_output()

Get whether or not output should be prefixed with the hostname.

=cut

sub tag_output {
    return $tag_output;
}

=item verbose()

Toggle/get whether or not to be verbose.

=cut

sub verbose {
    if ( @_ == 1 ) {
        $verbose = shift;
    }
    return $verbose;
}

# nasty brute force argument stealing :)
# BEGIN makes sure this runs before Getopt::* as long as that module
# isn't also called from within a BEGIN block
BEGIN {
    my @to_kill;

    for ( my $i=0; $i<@main::ARGV; $i++ ) {
        # skip anything after -- by itself, just like GNU convention
        # don't remove it though, so GetOptions can have a whack at processing
        last if ( $main::ARGV[$i] eq '--' );

        if ( $main::ARGV[$i] eq '--list' ) {
            push @to_kill, $i, $i+1;
            my $list = $main::ARGV[$i+1];

            # absolute path
            if ( -f $list ) {
                $machines_list = $list;
            }
            # short name
            elsif ( -f "$ENV{HOME}/.dsh/machines.$list" ) {
                $machines_list = "$ENV{HOME}/.dsh/machines.$list";
            }
            else {
                die "Could not read machine list in '$list' or '~/.dsh/machines.$list': $!";
            }
        }

        if ( $main::ARGV[$i] eq '--incl' ) {
            push @to_kill, $i, $i+1;
            my $f = $main::ARGV[$i+1];
            push @opt_filter_incl, qr/$f/;
        }
        if ( $main::ARGV[$i] eq '--excl' ) {
            push @to_kill, $i, $i+1;
            my $f = $main::ARGV[$i+1];
            push @opt_filter_excl, qr/$f/;
        }
        if ( $main::ARGV[$i] eq '--batch' ) {
            push @to_kill, $i, $i+1;
            $opt_batch = $main::ARGV[$i+1];
        }
        if ( $main::ARGV[$i] eq '-u' ) {
            push @to_kill, $i;
            $tag_output = undef;
        }
        if ( $main::ARGV[$i] eq '-i' ) {
            push @to_kill, $i, $i+1;
            my $sshkey = $main::ARGV[$i+1];
            $ssh_options .= " -o 'IdentityFile $sshkey'";
        }
        if ( $main::ARGV[$i] eq '-v' ) {
            push @to_kill, $i;
            $verbose = 1;
        }
        if ( $main::ARGV[$i] eq '--user' ) {
            push @to_kill, $i, $i+1;
            $remote_user = $main::ARGV[$i+1];
        }
        if ( $main::ARGV[$i] eq '--root' ) {
            push @to_kill, $i;
            $remote_user = 'root';
        }
    }

    # do them in reverse order
    foreach my $idx ( reverse sort @to_kill ) {
        delete $main::ARGV[$idx];
    }
}

=item set_screen_title()

Set the title in GNU screen if it's detected.

 set_screen_title("Cluster Netstat, Cluster: foobar");

=cut

sub set_screen_title {
  my $title = shift;

  if ($ENV{TERM} eq 'screen' or ($ENV{TERMCAP} and $ENV{TERMCAP} =~ /screen/)) {
    print "\033k$title\033\\";
  }
}

=item lock()

Simple lock backed on flock. For printing mostly, flock doesn't work on STDOUT.

=cut

sub lock {
    flock( $lock_fh, LOCK_EX );
}

=item unlock()

Opposite of above.

=cut

sub unlock {
  flock( $lock_fh, LOCK_UN );
}

=item my_tempfile()

Not secure. Generates a parseable-by-humans tempfile so people can
tell what junk in /tmp is from.

 my($fh, $name) = my_tempfile();

=cut

sub my_tempfile {
    my @parts;

    if ($ENV{USER} and $ENV{USER} ne 'root') {
        push @parts, $ENV{USER};
    }

    push @parts, basename($0);
    push @parts, Sys::Hostname::hostname;
    push @parts, CORE::time;

    my $filename = $tempdir . '/' . join('-', @parts);
       $filename =~ s/\s+//g;

    open(my $fh, "> $filename")
        or die "Couldn't open tempfile for write: $!";

    push @tempfiles, $filename;

    return($fh, $filename);
}

END {
    if ($$ == $mainpid) {
        if (($verbose or $debug) and @tempfiles > 0) {
            printf STDERR "Leaving tempfiles in $tempdir. They are:\n\t%s\n",
            join("\n\t", @tempfiles);
        }
        else {
            foreach my $tf (@tempfiles) {
                if ($tf =~ m#^$tempdir#) {
                    unlink($tf);
                }
            }
        }
    }

    eval { unlock(); }; # try to unlock
}

# track Net::SSH2 connections & related information in
# a separate object rather than having a bunch of globals
# stuff above will just bless right into this
# this AUTOLOAD just adds method syntax to a hash without dependencies
package DshPerlHostLoop::Bundle;

sub new {
  my($type, $self) = @_;
  return bless $self, $type;
}

sub AUTOLOAD {
    my($self, $value) = @_;
    our $AUTOLOAD;
    ( $_, $_, my $method ) = split /::/, $AUTOLOAD;
    if ($value) {
        $self->{$method} = $value;
    }
    return $self->{$method};
}

1;

# vim: et ts=4 sw=4 ai smarttab

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2011 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
