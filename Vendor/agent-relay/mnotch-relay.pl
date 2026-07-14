#!/usr/bin/perl
# MNotch agent hook relay.
#
# Installed as a Claude Code hook command. Reads the hook JSON from stdin,
# enriches it with the terminal locator from the environment, and forwards it
# to the MNotch agent server on 127.0.0.1. For blocking permission events it
# waits for MNotch to send back a decision and prints that JSON as the hook
# output; for all other events it fires and forgets.
#
# Degrades safely: if MNotch is not running (or replies slowly), it exits 0
# with no output so Claude Code falls through to the normal terminal prompt.

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

# --- read the hook payload -------------------------------------------------
my $stdin = do { local $/; <STDIN> } // '';

# --- MNotch connection details ---------------------------------------------
my $home = $ENV{HOME} // '';
my $support = "$home/Library/Application Support/MNotch";
my $token = read_file("$support/agent-token");
my $port  = read_file("$support/agent-port");
exit 0 unless defined $token && defined $port;
$token =~ s/\s+//g;
$port  =~ s/\s+//g;
exit 0 unless $token ne '' && $port =~ /^\d+$/;

# --- build the envelope ----------------------------------------------------
# The hook JSON already has session_id/transcript_path/cwd/tool_name/etc.
# We merge our own event/agent/terminal fields in as extra top-level keys by
# wrapping: MNotch reads envelope.event (the decoded hook object), so we send
# the raw hook JSON as the event and attach terminal info via env passed
# separately below. To keep it a single object, we splice fields into the
# hook JSON string.
my %extra = (
    agent_kind   => 'claude',
    term_program => $ENV{TERM_PROGRAM},
    term_session => $ENV{TERM_SESSION_ID},
    iterm_session=> $ENV{ITERM_SESSION_ID},
    tmux         => $ENV{TMUX},
    tmux_pane    => $ENV{TMUX_PANE},
);

my $event_json = splice_fields($stdin, \%extra);

# hook_event_name in the payload becomes our "event" key.
$event_json = ensure_event_key($event_json);

my $envelope = '{"token":"' . json_escape($token) . '","event":' . $event_json . "}\n";

# --- decide whether this is a blocking permission event --------------------
my $blocking = $stdin =~ /"hook_event_name"\s*:\s*"(PreToolUse|PermissionRequest)"/;

# --- connect & send --------------------------------------------------------
my $sock = IO::Socket::INET->new(
    PeerHost => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 2,
);
exit 0 unless $sock;   # MNotch not up → normal terminal flow
$sock->autoflush(1);
print $sock $envelope;

if (!$blocking) {
    close $sock;
    exit 0;
}

# --- blocking: wait for the decision line (self-timeout ~55s) --------------
my $select = IO::Select->new($sock);
if ($select->can_read(55)) {
    my $reply = <$sock>;
    close $sock;
    if (defined $reply && $reply =~ /\S/) {
        print $reply;   # MNotch's decision JSON becomes the hook output
        exit 0;
    }
}
close $sock;
# Timed out with no answer → defer to the terminal prompt.
print '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}';
exit 0;

# --- helpers ---------------------------------------------------------------
sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
}

sub json_escape {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    return $s;
}

# Insert extra "key":"value" pairs just after the opening brace of a JSON
# object string (skips undef values).
sub splice_fields {
    my ($json, $extra) = @_;
    my @pairs;
    for my $k (sort keys %$extra) {
        my $v = $extra->{$k};
        next unless defined $v && $v ne '';
        push @pairs, '"' . json_escape($k) . '":"' . json_escape($v) . '"';
    }
    return $json unless @pairs;
    my $inject = join(',', @pairs);
    # find first '{'
    if ($json =~ /\{/) {
        my $pos = $-[0] + 1;
        my $rest = substr($json, $pos);
        # if object is non-empty, add a trailing comma
        my $sep = ($rest =~ /^\s*"/) ? ',' : '';
        substr($json, $pos, 0) = $inject . $sep;
    }
    return $json;
}

# Copy hook_event_name into a top-level "event" key MNotch reads.
sub ensure_event_key {
    my ($json) = @_;
    if ($json =~ /"hook_event_name"\s*:\s*"([^"]+)"/) {
        my $name = $1;
        return splice_fields($json, { event => $name });
    }
    return $json;
}
