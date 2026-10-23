#!/usr/bin/perl
# Local, bounded hook relay. On every failure preserve the agent's native prompt.
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use JSON::PP qw(decode_json encode_json);
$SIG{PIPE} = 'IGNORE';
$SIG{ALRM} = sub { exit 0 };
alarm 2;
my $stdin = '';
while (1) {
    my $chunk;
    my $n = sysread(STDIN, $chunk, 65536);
    exit 0 unless defined $n;
    last if $n == 0;
    $stdin .= $chunk;
    exit 0 if length($stdin) > 900000;
}
alarm 60;
my $payload = eval { decode_json($stdin) };
exit 0 unless ref($payload) eq 'HASH';
my $kind = $ARGV[0] // 'claude';
my $support = $ENV{MNOTCH_SUPPORT_DIRECTORY}
    // (($ENV{HOME} // '') . '/Library/Application Support/MNotch');
my $token = read_file("$support/agent-token");
my $port = read_file("$support/agent-port");
exit 0 unless defined $token && defined $port;
$token =~ s/\s+//g; $port =~ s/\s+//g;
exit 0 unless length($token) > 0 && $port =~ /^\d+$/ && $port > 0 && $port <= 65535;
my %extra = (
    agent_kind => $kind,
    term_program => $ENV{TERM_PROGRAM} // ($kind eq 'codex' ? 'codex' : undef),
    term_session => $ENV{TERM_SESSION_ID}, iterm_session => $ENV{ITERM_SESSION_ID},
    tmux => $ENV{TMUX}, tmux_pane => $ENV{TMUX_PANE},
    host_bundle => $ENV{__CFBundleIdentifier},
);
for my $key (keys %extra) {
    $payload->{$key} = $extra{$key} if defined $extra{$key} && $extra{$key} ne '';
}
my $event = $payload->{hook_event_name};
exit 0 if !defined($event) || ref($event);
$payload->{event} = $event;
my $envelope = eval { encode_json({ token => $token, event => $payload }) . "\n" };
exit 0 unless defined $envelope && length($envelope) <= 1000000;
my $sock = IO::Socket::INET->new(
    PeerHost => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 2
);
exit 0 unless $sock;
$sock->autoflush(1);
print $sock $envelope or exit 0;
if ($event ne 'PreToolUse' && $event ne 'PermissionRequest') {
    close $sock;
    exit 0;
}
my $select = IO::Select->new($sock);
my $deadline = time + 55;
my $reply = '';
while (1) {
    my $remaining = $deadline - time;
    last if $remaining <= 0 || !$select->can_read($remaining);
    my $chunk;
    my $n = sysread($sock, $chunk, 4096);
    last unless defined($n) && $n > 0;
    $reply .= $chunk;
    last if length($reply) > 65536;
    if ($reply =~ /\n/) {
        $reply =~ s/\n.*$/\n/s;
        my $decoded = eval { decode_json($reply) };
        if (ref($decoded) eq 'HASH') {
            print $reply;
            close $sock;
            exit 0;
        }
        last;
    }
}
close $sock;
if ($event eq 'PreToolUse') {
    print encode_json({ hookSpecificOutput => {
        hookEventName => 'PreToolUse', permissionDecision => 'ask'
    }});
}
exit 0;
sub read_file {
    my ($path) = @_;
    open my $file, '<', $path or return undef;
    my $content;
    read($file, $content, 4096);
    close $file;
    return $content;
}
