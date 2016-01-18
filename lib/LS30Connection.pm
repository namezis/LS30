#!/usr/bin/env perl
#   Copyright (C) 2010-2014, Nick Andrew <nick@nick-andrew.net>
#   Licensed under the terms of the GNU General Public License, Version 3

=head1 NAME

LS30Connection - Maintain a connection to LS30 device

=head1 DESCRIPTION

This class keeps a TCP connection to an LS30 device and performs some of
the protocol decoding.

It is a subclass of AlarmDaemon::ServerSocket.

=head1 METHODS

=over

=cut

package LS30Connection;

use strict;
use warnings;

use Data::Dumper qw(Dumper);
use Date::Format qw(time2str);
use AnyEvent qw();

use base qw(AlarmDaemon::ServerSocket);

# ---------------------------------------------------------------------------

=item I<new($server_address, %args)>

Return a new LS30Connection. The server address defaults to env LS30_SERVER.

Optional args hashref:  See perldoc for AlarmDaemon::ServerSocket

  reconnect                  Set default reconnection functions (boolean)

=cut

sub new {
	my ($class, $server_address, %args) = @_;

	if (!defined $server_address) {
		$server_address = $ENV{'LS30_SERVER'};

		if (!$server_address) {
			die "Environment LS30_SERVER must be set to host:port of LS30 server";
		}
	}

	if ($args{reconnect}) {

		$args{on_connect_fail} = sub {
			LS30::Log::error("LS30Connection: Connection to $server_address failed, retrying");
			shift->retryConnect();
		};

		$args{on_disconnect} = sub {
			LS30::Log::error("LS30Connection: Disconnected from $server_address, retrying");
			shift->retryConnect();
		};
	}

	my $self = $class->SUPER::new($server_address, %args);
	bless $self, $class;

	return $self;
}


# ---------------------------------------------------------------------------

=item I<sendCommand($string)>

Send a command to the connected socket.

Dies if not presently connected.

=cut

sub sendCommand {
	my ($self, $string) = @_;

	$self->send($string);
	LS30::Log::debug("Sent: $string");
}


# ---------------------------------------------------------------------------

=item I<processLine($line)>

Process one full line of received data. Run an appropriate handler.

Since the LS30 can garble its output, also use some heuristics to
determine if a line which makes no sense in total can be processed
in part.

=cut

sub processLine {
	my ($self, $line) = @_;

	if ($line =~ /^MINPIC=([0-9a-f]+)$/) {
		my $minpic = $1;
		$self->_runonfunc('MINPIC', $minpic);
		return;
	}

	if ($line =~ /^XINPIC=([0-9a-f]+)$/) {
		my $minpic = $1;
		$self->runHandler('XINPIC', $minpic);
		return;
	}

	if ($line =~ /^\(([0-9a-f]+)\)$/) {
		my $contact_id = $1;
		$self->runHandler('CONTACTID', $contact_id);
		return;
	}

	if ($line eq '!&') {

		# This is only a prompt
		return;
	}

	if ($line =~ /^(!.+&)$/) {
		my $response = $1;

		# Special handling for 'new device enrolled' messages which are not
		# a response to a command, but are sent at the time the device is
		# enrolled.
		if ($response =~ /^!i[bcefm]l[0-9a-f]{14}&$/) {
			$self->_runonfunc('added_device', $response);
			return;
		}

		if ($response =~ /^!i[bcefm]lno&$/) {
			# Time limit expired; no device added
			# The time delay is a *maximum* of 60 seconds; may be less.
			$self->_runonfunc('added_device', $response);
			return;
		}

		$self->_runonfunc('response', $response);
		return;
	}

	if ($line =~ /^(AT.+)/) {

		# Ignore AT command
		$self->runHandler('AT', $line);
		return;
	}

	if ($line =~ /^(GSM=.+)/) {

		# Ignore GSM command
		$self->runHandler('GSM', $line);
		return;
	}

	LS30::Log::timePrint("Unrecognised: $line");

	# Try munged I/O
	if ($line =~ /^(.+)(MINPIC=.+)/) {
		my ($junk, $minpic) = ($1, $2);
		LS30::Log::timePrint("Skipping junk $junk");
		$self->processLine($minpic);
		return;
	}

	if ($line =~ /^(.+)(XINPIC=.+)/) {
		my ($junk, $xinpic) = ($1, $2);
		LS30::Log::timePrint("Skipping junk $junk");
		$self->processLine($xinpic);
		return;
	}

	if ($line =~ /^(.+)(\(.+\))/) {
		my ($junk, $contactid) = ($1, $2);
		LS30::Log::timePrint("Skipping junk $junk");
		$self->processLine($contactid);
		return;
	}

	if ($line =~ /^(.+)(!.+&)/) {
		my ($junk, $response) = ($1, $2);
		LS30::Log::timePrint("Skipping junk $junk");
		$self->processLine($response);
		return;
	}

	if ($line =~ /^(.+)(AT.+)/) {
		my ($junk, $at) = ($1, $2);
		LS30::Log::timePrint("Skipping junk $junk");
		$self->processLine($at);
		return;
	}

	if ($line =~ /^(.+)(GSM=.+)/) {
		my ($junk, $gsm) = ($1, $2);
		LS30::Log::timePrint("Skipping junk $junk");
		$self->processLine($gsm);
		return;
	}

	LS30::Log::timePrint("Ignoring: $line");
}

# ---------------------------------------------------------------------------
# Set/Get and/or run a function
# ---------------------------------------------------------------------------

sub _onfunc {
	my $self = shift;
	my $name = shift;

	if (scalar @_) {
		$self->{on_func}->{$name} = shift;
		return $self;
	}

	return $self->{on_func}->{$name};
}

sub _runonfunc {
	my $self = shift;
	my $name = shift;

	my $sub = $self->{on_func}->{$name};
	if (defined $sub) {
		$sub->(@_);
	}
}

# ---------------------------------------------------------------------------

=item I<onMINPIC($sub)>

Set or clear or get sub to be called when a MINPIC line is received.

=cut

sub onMINPIC {
	my $self = shift;

	return $self->_onfunc('MINPIC', @_);
}

# ---------------------------------------------------------------------------

=item I<onResponse($sub)>

Set or clear or get sub to be called when a response line is received.

=cut

sub onResponse {
	my $self = shift;

	return $self->_onfunc('response', @_);
}

# ---------------------------------------------------------------------------

=item I<onAddedDevice($sub)>

Set or clear or get sub to be called when a specific line indicating an
added device has been received.

=cut

sub onAddedDevice {
	my $self = shift;

	return $self->_onfunc('added_device', @_);
}

# ---------------------------------------------------------------------------

=item I<setHandler($object)>

Keep a reference to the object which will process all our emitted events.

=cut

sub setHandler {
	my ($self, $object) = @_;

	$self->{handler} = $object;
}


# ---------------------------------------------------------------------------

=item I<runHandler($type, @args)>

Run the handler function appropriate to the specified type $type.
Further arguments depend on the value of $type.

=cut

sub runHandler {
	my $self = shift;
	my $type = shift;

	my $object = $self->{handler};

	if (!defined $object) {
		LS30::Log::error("Cannot run handler for $type");
		return;
	}

	if ($type eq 'MINPIC') {
		die "Obsolete";
	} elsif ($type eq 'XINPIC') {
		$object->handleXINPIC(@_);
	} elsif ($type eq 'CONTACTID') {
		$object->handleCONTACTID(@_);
	} elsif ($type eq 'Response') {
		die "Obsolete runHandler Response";
	} elsif ($type eq 'AT') {
		$object->handleAT(@_);
	} elsif ($type eq 'GSM') {
		$object->handleGSM(@_);
	} else {
		LS30::Log::error("No handler function defined for $type");
	}
}

=back

=cut

1;
