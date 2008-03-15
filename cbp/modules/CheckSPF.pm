# SPF checking module
# Copyright (C) 2008, LinuxRulz
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.


package cbp::modules::CheckSPF;

use strict;
use warnings;


use cbp::logging;
use cbp::dblayer;
use cbp::protocols;

use Mail::SPF;


# User plugin info
our $pluginInfo = {
	name 			=> "SPF Check Plugin",
	priority		=> 70,
	init		 	=> \&init,
	request_process	=> \&check,
};


# Our config
my %config;

# SPF server
my $spf_server;


# Create a child specific context
sub init {
	my $server = shift;
	my $inifile = $server->{'inifile'};

	# Defaults
	$config{'enable'} = 0;

	# Parse in config
	if (defined($inifile->{'checkspf'})) {
		foreach my $key (keys %{$inifile->{'checkspf'}}) {
			$config{$key} = $inifile->{'checkspf'}->{$key};
		}
	}

	# Check if enabled
	if ($config{'enable'} =~ /^\s*(y|yes|1|on)\s*$/i) {
		$server->log(LOG_NOTICE,"  => CheckSPF: enabled");
		$config{'enable'} = 1;
		$spf_server = Mail::SPF::Server->new();
	}
}


# Do our check
sub check {
	my ($server,$sessionData) = @_;

	# If we not enabled, don't do anything
	return CBP_SKIP if (!$config{'enable'});

	# We only valid in the RCPT state
	return CBP_SKIP if (!defined($sessionData->{'ProtocolState'}) || $sessionData->{'ProtocolState'} ne "RCPT");

	# We cannot do SPF on <>
	return CBP_SKIP if (!defined($sessionData->{'Sender'}) || $sessionData->{'Sender'} eq "");

	# Check if we have any policies matched, if not just pass
	return CBP_SKIP if (!defined($sessionData->{'Policy'}));

	# Policy we're about to build
	my %policy;
	
	# Loop with priorities, high to low
	foreach my $priority (sort {$a <=> $b} keys %{$sessionData->{'Policy'}}) {

		# Loop with policies
		foreach my $policyID (@{$sessionData->{'Policy'}->{$priority}}) {

			my $sth = DBSelect("
				SELECT
					UseSPF, RejectFailedSPF, AddSPFHeader

				FROM
					checkspf

				WHERE
					PolicyID = ".DBQuote($policyID)."
					AND Disabled = 0
			");
			if (!$sth) {
				$server->log(LOG_ERR,"[CHECKSPF] Database query failed: ".cbp::dblayer::Error());
				return $server->protocol_response(PROTO_DB_ERROR);
			}
			while (my $row = $sth->fetchrow_hashref()) {
				# If defined, its to override
				if (defined($row->{'UseSPF'})) {
					$policy{'UseSPF'} = $row->{'UseSPF'};
				}
				# If defined, its to override
				if (defined($row->{'RejectFailedSPF'})) {
					$policy{'RejectFailedSPF'} = $row->{'RejectFailedSPF'};
				}
				# If defined, its to override
				if (defined($row->{'AddSPFHeader'})) {
					$policy{'AddSPFHeader'} = $row->{'AddSPFHeader'};
				}
			} # while (my $row = $sth->fetchrow_hashref())
		} # foreach my $policyID (@{$sessionData->{'Policy'}->{$priority}})
	} # foreach my $priority (sort {$a <=> $b} keys %{$sessionData->{'Policy'}})

	# Check if we must use SPF
	if (defined($policy{'UseSPF'}) && $policy{'UseSPF'} eq "1") {
		# Create SPF request
		my $rqst = Mail::SPF::Request->new(
				'scope' => 'mfrom', # or 'helo', 'pra'
				'identity' => $sessionData->{'Sender'},
				'ip_address' => $sessionData->{'ClientAddress'},
				'helo_identity' => $sessionData->{'Helo'}, # optional,
		);

		# Get result
		my $result = $spf_server->process($rqst);
	
		$server->log(LOG_DEBUG,"[CHECKSPF] SPF result: ".$result->local_explanation);

		# Make reason more pretty
		my $reason;
		(my $local_reason = $result->local_explanation) =~ s/:/,/;
		if ($result->can('authority_explanation')) {
			$reason = $result->authority_explanation . "; $local_reason";
		} else {
			$reason = $local_reason;
		}

		# Intended action is accept
		if ($result->code eq "pass") {
			$server->maillog("module=CheckSPF, action=none, host=%s, helo=%s, from=%s, to=%s, reason=pass",
					$sessionData->{'ClientAddress'},
					$sessionData->{'Helo'},
					$sessionData->{'Sender'},
					$sessionData->{'Recipient'});

		# Intended action is reject
		} elsif ($result->code eq "fail") {
			my $action = "none";

			# Check if we need to reject
			if (defined($policy{'RejectFailedSPF'}) && $policy{'RejectFailedSPF'} eq "1") {
				$action = "reject";
			} elsif (defined($policy{'AddSPFHeader'}) && $policy{'AddSPFHeader'} eq "1") {
				$action = "add_header";
			}

			$server->maillog("module=CheckSPF, action=$action, host=%s, helo=%s, from=%s, to=%s, reason=fail",
					$sessionData->{'ClientAddress'},
					$sessionData->{'Helo'},
					$sessionData->{'Sender'},
					$sessionData->{'Recipient'});

			# Check if we need to reject
			if ($action eq "reject") {
				return $server->protocol_response(PROTO_REJECT,"Failed SPF check; $reason");
			} elsif ($action eq "add_header") {
				return $server->protocol_response(PROTO_PREPEND,$result->received_spf_header);
			}

		# Intended action is accept and mark
		} elsif ($result->code eq "softfail") {
			my $action = "none";

			# Check if we need to add a header
			if (defined($policy{'AddSPFHeader'}) && $policy{'AddSPFHeader'} eq "1") {
				$action = "add_header";
			}

			$server->maillog("module=CheckSPF, action=$action, host=%s, helo=%s, from=%s, to=%s, reason=softfail",
					$sessionData->{'ClientAddress'},
					$sessionData->{'Helo'},
					$sessionData->{'Sender'},
					$sessionData->{'Recipient'});

			# Check if we need to add a header
			if ($action eq "add_header") {
				return $server->protocol_response(PROTO_PREPEND,$result->received_spf_header);
			}

		# Intended action is accept
		} elsif ($result->code eq "neutral") {
			my $action = "none";

			# Check if we need to add a header
			if (defined($policy{'AddSPFHeader'}) && $policy{'AddSPFHeader'} eq "1") {
				$action = "add_header";
			}

			$server->maillog("module=CheckSPF, action=$action, host=%s, helo=%s, from=%s, to=%s, reason=neutral",
					$sessionData->{'ClientAddress'},
					$sessionData->{'Helo'},
					$sessionData->{'Sender'},
					$sessionData->{'Recipient'});

			# Check if we need to add a header
			if ($action eq "add_header") {
				return $server->protocol_response(PROTO_PREPEND,$result->received_spf_header);
			}

		# Intended action is unspecified
		} elsif ($result->code eq "permerror") {
			my $action = "none";

			# Check if we need to reject
			if (defined($policy{'RejectFailedSPF'}) && $policy{'RejectFailedSPF'} eq "1") {
				$action = "reject";
			} elsif (defined($policy{'AddSPFHeader'}) && $policy{'AddSPFHeader'} eq "1") {
				$action = "add_header";
			}

			$server->maillog("module=CheckSPF, action=$action, host=%s, helo=%s, from=%s, to=%s, reason=permerror",
					$sessionData->{'ClientAddress'},
					$sessionData->{'Helo'},
					$sessionData->{'Sender'},
					$sessionData->{'Recipient'});

			# Check if we need to reject
			if ($action eq "reject") {
				return $server->protocol_response(PROTO_REJECT,"Failed SPF check; $reason");
			} elsif ($action eq "add_header") {
				return $server->protocol_response(PROTO_PREPEND,$result->received_spf_header);
			}

		# Intended action is either accept or reject
		} elsif ($result->code eq "temperror") {
			my $action = "none";

			# Check if we need to reject
			if (defined($policy{'RejectFailedSPF'}) && $policy{'RejectFailedSPF'} eq "1") {
				$action = "defer";
			} elsif (defined($policy{'AddSPFHeader'}) && $policy{'AddSPFHeader'} eq "1") {
				$action = "add_header";
			}

			$server->maillog("module=CheckSPF, action=$action, host=%s, helo=%s, from=%s, to=%s, reason=temperror",
					$sessionData->{'ClientAddress'},
					$sessionData->{'Helo'},
					$sessionData->{'Sender'},
					$sessionData->{'Recipient'});

			# Check if we need to defer
			if ($action eq "defer") {
				return $server->protocol_response(PROTO_DEFER,"Failed SPF check; $reason");
			} elsif ($action eq "add_header") {
				return $server->protocol_response(PROTO_PREPEND,$result->received_spf_header);
			}


		# Intended action is accept
		} elsif ($result->code eq "none") {
			my $action = "none";

			if (defined($policy{'AddSPFHeader'}) && $policy{'AddSPFHeader'} eq "1") {
				$action = "add_header";
			}

			$server->maillog("module=CheckSPF, action=$action, host=%s, helo=%s, from=%s, to=%s, reason=no_spf_record",
					$sessionData->{'ClientAddress'},
					$sessionData->{'Helo'},
					$sessionData->{'Sender'},
					$sessionData->{'Recipient'});

			if ($action eq "add_header") {
				return $server->protocol_response(PROTO_PREPEND,$result->received_spf_header);
			}
		}
	}

	return CBP_CONTINUE;
}


1;
# vim: ts=4
