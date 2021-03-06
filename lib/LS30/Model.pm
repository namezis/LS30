#!/usr/bin/env perl
#   Copyright (C) 2010-2014, Nick Andrew <nick@nick-andrew.net>
#   Licensed under the terms of the GNU General Public License, Version 3

=head1 NAME

LS30::Model - A representation of an LS30 alarm system

=head1 SYNOPSIS

  #   my $model = LS30::Model->new();
  #   my $current_mode = $model->getSetting('Operation Mode')->recv;
  #   $model->setSetting('Operation Mode', 'Arm');

=head1 DESCRIPTION

This class models the internal state of an LS30 alarm system.

=head1 METHODS

=over

=cut

package LS30::Model;

use strict;
use warnings;

use LS30::Device qw();
use LS30::Log qw();
use LS30::ResponseMessage qw();

=item I<new()>

Return a new instance of this class.

=cut

sub new {
	my ($class) = @_;

	my $self = {
		settings     => {},
		devices      => {},
		device_count => {},
		upstream     => undef,
	};

	bless $self, $class;

	return $self;
}

=item I<upstream($upstream)>

If $upstream is provided, then set the upstream object and return $self,
else return the upstream object.

=cut

sub upstream {
	my $self = shift;

	if (scalar @_) {
		$self->{upstream} = shift;
		if ($self->{upstream}) {
			$self->{upstream}->onMINPIC(sub { $self->handleMINPIC(@_) });
		}
		return $self;
	}

	return $self->{upstream};
}

# ---------------------------------------------------------------------------
# Get or set a named setting
# ---------------------------------------------------------------------------

sub _setting {
	my $self = shift;
	my $setting_name = shift;

	if (scalar @_) {
		$self->{settings}->{$setting_name} = shift;
	}

	return $self->{settings}->{$setting_name};
}

=item I<getSetting($setting_name, $cached)>

Return a condvar which will receive
the current value of $setting_name (which is defined in LS30Command).

If $cached is set, a cached value may be returned, otherwise upstream is
queried and the value is cached before being returned through the condvar.

Example:

    # Synchronous code
    # my $value = $model->getSetting('Operation Mode', 1)->recv;

    # Asynchronous
    # my $cv = $model->getSetting('Operation Mode', 1);
    # $cv->cb(sub {
    #    my $value = $cv->recv;
    #    # ...
    # });

=cut

sub getSetting {
	my ($self, $setting_name, $cached) = @_;

	my $cv = AnyEvent->condvar;

	my $hr = LS30Command::getCommand($setting_name);
	if (!defined $hr || !$hr->{is_setting}) {
		LS30::Log::error("Is not a setting: <$setting_name>");
		$cv->send(undef);
		return $cv;
	}

	my $key = $hr->{key};
	my $value = $self->_setting($setting_name);

	if ($cached && defined $value) {
		$cv->send($value);
		return $cv;
	}

	my $upstream = $self->upstream();

	if ($upstream) {
		my $cv2 = $upstream->getSetting($setting_name, $cached);
		$cv2->cb(sub {
			my $value = $cv2->recv;
			$self->_setting($setting_name, $value);
			$cv->send($value);
		});
		return $cv;
	}

	if (defined $value) {
		$cv->send($value);
		return $cv;
	}

	# TODO Return a default value.
	$cv->send(undef);
	return $cv;
}

=item I<setSetting($setting_name, $value)>

Return a condvar associated with setting
a new value for $setting_name (which is defined in LS30Command).

If an upstream is set, the value is always first propagated to upstream.

Return (through the condvar) undef if ok, an error message otherwise.

=cut

sub setSetting {
	my ($self, $setting_name, $value) = @_;

	my $cv = AnyEvent->condvar;

	my $hr = LS30Command::getCommand($setting_name);
	if (!defined $hr || !$hr->{is_setting}) {
		my $err = "Is not a setting: <$setting_name>";
		$cv->send($err);
		return $cv;
	}

	my $raw_value = LS30Command::testSettingValue($setting_name, $value);
	if (!defined $raw_value) {
		my $err = "Value <$value> is not valid for setting <$setting_name>";
		$cv->send($err);
		return $cv;
	}

	my $upstream = $self->upstream();

	if ($upstream) {
		my $cv2 = $upstream->setSetting($setting_name, $value);
		$cv2->cb(sub {
			my $rc = $cv2->recv;
			if (!defined $rc) {
				# Ok, so cache the saved value
				$self->_setting($setting_name, $value);
			}
			$cv->send($rc);
		});
		return $cv;
	}

	$self->_setting($setting_name, $value);
	$cv->send(undef);
	return $cv;
}

=item I<clearSetting($setting_name)>

Return a condvar associated with clearing
the value for $setting_name (which is defined in LS30Command).

Presumably this means returning the setting to a default value.

If an upstream is set, the request is always first propagated to upstream.

Return (through the condvar) undef if ok, or an error message otherwise.

=cut

sub clearSetting {
	my ($self, $setting_name) = @_;

	my $cv = AnyEvent->condvar;

	my $hr = LS30Command::getCommand($setting_name);
	if (!defined $hr || !$hr->{is_setting}) {
		my $err = "Is not a setting: <$setting_name>\n";
		$cv->send($err);
		return $cv;
	}

	my $key = $hr->{key};

	my $upstream = $self->upstream();

	if ($upstream) {
		my $cv2 = $upstream->clearSetting($setting_name);
		$cv2->cb(sub {
			my $rc = $cv2->recv;
			if (!defined $rc) {
				$self->_setting($setting_name, undef);
			}
			$cv->send($rc);
		});
		return $cv;
	}

	$self->_setting($setting_name, undef);
	$cv->send(undef);
	return $cv;
}


# ---------------------------------------------------------------------------
# Return true if argument is a valid device type ('Burglar Sensor' etc)
# ---------------------------------------------------------------------------

sub _testDeviceType {
	my ($device_type) = @_;

	if (!LS30::Type::getCode('Device Type', $device_type)) {
		return 0;
	}

	return 1;
}

=item I<getDeviceCount($device_type, $cached)>

Return a condvar which will return the count of how many devices
of the specified type are registered.

If $cached == 1, a cached count may be returned.

=cut

sub getDeviceCount {
	my ($self, $device_type, $cached) = @_;

	my $cv = AnyEvent->condvar;

	if (!_testDeviceType($device_type)) {
		LS30::Log::error("Invalid device type <$device_type>");
		$cv->send(undef);
		return $cv;
	}

	my $value = $self->{device_count}->{$device_type};

	if ($cached && defined $value) {
		$cv->send($value);
		return $cv;
	}

	my $upstream = $self->upstream();

	if ($upstream) {
		my $cv2 = $upstream->getDeviceCount($device_type, $cached);
		$cv2->cb(sub {
			my $value = $cv2->recv;
			$self->{device_count}->{$device_type} = $value if (defined $value);
			$cv->send($value);
		});
		return $cv;
	}

	if (defined $value) {
		$cv->send($value);
		return $cv;
	}

	# TODO Return a default value.
	$cv->send(0);
	return $cv;
}


# ---------------------------------------------------------------------------

=item I<getDeviceStatus($device_type, $device_number, $cached)>

Get the status of the specified device (specified by device_type and device_number)

Return (through a condvar) an instance of LS30::Device, or undef if error.

If $cached == 1, a cached device object may be returned.

=cut

sub getDeviceStatus {
	my ($self, $device_type, $device_number, $cached) = @_;

	my $cv = AnyEvent->condvar;

	if (!_testDeviceType($device_type)) {
		LS30::Log::error("Invalid device type <$device_type>");
		$cv->send(undef);
		return $cv;
	}

	if ($device_number < 0) {
		LS30::Log::error("Invalid device number <$device_number>");
		$cv->send(undef);
		return $cv;
	}

	# Grab a count of how many devices of this type
	# Force cache this call for devices 1-n to avoid repeating it
	my $howmany_cv = $self->getDeviceCount($device_type, $cached || ($device_number != 0));
	$howmany_cv->cb(sub {
		my $howmany = $howmany_cv->recv();

		if ($device_number >= $howmany) {
			# Asked for a device beyond the end of the array
			LS30::Log::error("Device number beyond end of array.");
			$cv->send(undef);
			return;
		}

		my $obj = $self->{devices}->{$device_type}->[$device_number];

		if ($cached && defined $obj) {
			# Return cached object
			$cv->send($obj);
			return;
		}

		my $upstream = $self->upstream();

		if ($upstream) {
			my $cv2 = $upstream->getDeviceStatus($device_type, $device_number, $cached);
			$cv2->cb(sub {
				my $value = $cv2->recv;
				$self->{devices}->{$device_type}->[$device_number] = $value if (defined $value);
				$cv->send($value);
			});
			return;
		}

		if (defined $obj) {
			$cv->send($obj);
			return;
		}

		# There is no object
		$cv->send(undef);
	});

	return $cv;
}



# ---------------------------------------------------------------------------
# _initDevices: Initialise all devices by querying upstream
# Returns a condvar which will 'send' when all is complete.
# ---------------------------------------------------------------------------

sub _initDevices {
	my ($self) = @_;

	my $upstream = $self->upstream;
	return 0 if (!$upstream);

	my $cv = AnyEvent->condvar;

	$cv->begin;

	# Get list of device types ('Burglar Sensor' etc)
	my @device_types = LS30::Type::listStrings('Device Type');

	foreach my $device_type (@device_types) {
		# Get count of number of this type of device
		my $query = {title => 'Device Count', device_type => $device_type};
		my $cmd = LS30Command::queryCommand($query);
		if (!$cmd) {
			LS30::Log::error("Unable to query device count for type <$device_type>");
			next;
		}

		$cv->begin;

		my $cv2 = $upstream->queueCommand($cmd);
		$cv2->cb(sub {
			my $response = $cv2->recv();
			my $resp_obj = LS30::ResponseMessage->new($response);
			my $count = $resp_obj->value;

			if ($count > 0) {
				foreach my $device_number (0 .. $count - 1) {
					my $cmd = LS30Command::getDeviceStatus($device_type, $device_number);

					$cv->begin;
					my $cv3 = $upstream->queueCommand($cmd);
					$cv3->cb(sub {
						my $resp2 = $cv3->recv();
						my $resp2_obj = LS30::ResponseMessage->new($resp2);
						my $device = LS30::Device->newFromResponse($resp2_obj);
						my $device_id = $device->device_id;
						$self->{devices}->{$device_type}->{$device_id} = $device;
						$cv->end;
					});
				}
			}

			$cv->end;
		});
	}

	$cv->end;

	# Success
	return $cv;
}


# ---------------------------------------------------------------------------

=item I<onMINPIC($cb)>

Set callback $cb on every MINPIC received.

Will propagate upstream.

=cut

sub onMINPIC {
	my $self = shift;

	if (scalar @_) {
		$self->{on_minpic} = shift;
		return $self;
	}


	return $self->{on_minpic};
}

# ---------------------------------------------------------------------------

=item I<handleMINPIC($string)>

Handle a received MINPIC. Do whatever local processing is required, then
hand the string off to our callback function, if any.

=cut

sub handleMINPIC {
	my ($self, $string) = @_;

	if ($self->{on_minpic}) {
		$self->{on_minpic}->($string);
	}
}

=back

=cut

1;
