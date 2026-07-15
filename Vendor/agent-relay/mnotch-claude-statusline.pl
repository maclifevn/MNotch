#!/usr/bin/perl
# MNotch Claude quota bridge.
#
# Claude Code invokes this as its statusLine command and provides official
# 5-hour / 7-day rate-limit data on stdin after API responses. The bridge
# stores a minimal last-known snapshot, forwards it to MNotch over the same
# authenticated localhost channel as agent hooks, then runs the user's
# previous status-line command unchanged.

use strict;
use warnings;
use IO::Socket::INET;
use JSON::PP qw(decode_json encode_json);
use Scalar::Util qw(looks_like_number);

my $stdin = do { local $/; <STDIN> } // '';
my $home = $ENV{HOME} // '';
my $support = "$home/Library/Application Support/MNotch";

my $decoded = eval { decode_json($stdin) };
if (ref($decoded) eq 'HASH' && ref($decoded->{rate_limits}) eq 'HASH') {
    my %rate_limits;
    for my $name (qw(five_hour seven_day)) {
        my $source = $decoded->{rate_limits}{$name};
        next unless ref($source) eq 'HASH';
        my %window;
        if (defined $source->{used_percentage}
            && looks_like_number($source->{used_percentage})) {
            $window{used_percentage} = 0 + $source->{used_percentage};
        }
        if (defined $source->{resets_at}
            && looks_like_number($source->{resets_at})) {
            $window{resets_at} = 0 + $source->{resets_at};
        }
        $rate_limits{$name} = \%window if exists $window{used_percentage};
    }
    if (keys %rate_limits) {
        my $snapshot = {
            event            => 'quota',
            agent_kind       => 'claude',
            quota_updated_at => time,
            rate_limits      => \%rate_limits,
        };
        persist_snapshot($snapshot, "$support/claude-quota.json");
        forward_snapshot($snapshot, $support);
    }
}

# Preserve a pre-existing status line. Swift stores only the previous command
# in this private 0600 file and restores the full settings object on uninstall.
my $previous = slurp("$support/claude-statusline-command");
if (defined $previous
    && $previous =~ /\S/
    && $previous !~ /mnotch-claude-statusline\.pl/) {
    my $shell = $ENV{SHELL} // '/bin/zsh';
    $shell = '/bin/zsh' unless -x $shell;
    if (open my $child, '|-', $shell, '-lc', $previous) {
        print {$child} $stdin;
        close $child;
    }
}
exit 0;

sub forward_snapshot {
    my ($snapshot, $dir) = @_;
    my $token = slurp("$dir/agent-token");
    my $port  = slurp("$dir/agent-port");
    return unless defined $token && defined $port;
    $token =~ s/\s+//g;
    $port  =~ s/\s+//g;
    return unless $token ne '' && $port =~ /^\d+$/;

    my $sock = IO::Socket::INET->new(
        PeerHost => '127.0.0.1',
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 1,
    ) or return;
    $sock->autoflush(1);
    print {$sock} encode_json({ token => $token, event => $snapshot }) . "\n";
    close $sock;
}

sub persist_snapshot {
    my ($snapshot, $path) = @_;
    my $temp = "$path.$$";
    return unless open my $fh, '>', $temp;
    chmod 0600, $temp;
    print {$fh} encode_json($snapshot);
    close $fh;
    rename $temp, $path or unlink $temp;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}
