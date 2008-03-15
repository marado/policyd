# Greylisting module
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


package cbp::modules::Greylisting;

use strict;
use warnings;


use cbp::logging;
use cbp::dblayer;
use cbp::system;
use cbp::protocols;


# User plugin info
our $pluginInfo = {
	name 			=> "Greylisting Plugin",
	priority		=> 60,
	init		 	=> \&init,
	request_process	=> \&check,
	cleanup		 	=> \&cleanup,
};


# Our config
my %config;


# Create a child specific context
sub init {
	my $server = shift;
	my $inifile = $server->{'inifile'};

	# Defaults
	$config{'enable'} = 0;

	# Parse in config
	if (defined($inifile->{'greylisting'})) {
		foreach my $key (keys %{$inifile->{'greylisting'}}) {
			$config{$key} = $inifile->{'greylisting'}->{$key};
		}
	}

	# Check if enabled
	if ($config{'enable'} =~ /^\s*(y|yes|1|on)\s*$/i) {
		$server->log(LOG_NOTICE,"  => Greylisting: enabled");
		$config{'enable'} = 1;
	}
}


# Do our check
sub check {
	my ($server,$sessionData) = @_;


	# If we not enabled, don't do anything
	return CBP_SKIP if (!$config{'enable'});

	# We only valid in the RCPT state
	return CBP_SKIP if (!defined($sessionData->{'ProtocolState'}) || $sessionData->{'ProtocolState'} ne "RCPT");
	
	# Check if we have any policies matched, if not just pass
	return CBP_SKIP if (!defined($sessionData->{'Policy'}));

	# Policy we're about to build
	my %policy;

	# Loop with priorities, low to high
	foreach my $priority (sort {$a <=> $b} keys %{$sessionData->{'Policy'}}) {

		# Loop with policies
		foreach my $policyID (@{$sessionData->{'Policy'}->{$priority}}) {

			# Grab greylisting info
			my $sth = DBSelect("
				SELECT
					UseGreylisting, GreylistPeriod,
					Track,
					GreylistAuthValidity, GreylistUnAuthValidity,

					UseAutoWhitelist, AutoWhitelistPeriod, AutoWhitelistCount, AutoWhitelistPercentage,
					UseAutoBlacklist, AutoBlacklistPeriod, AutoBlacklistCount, AutoBlacklistPercentage

				FROM
					greylisting

				WHERE
					PolicyID = ".DBQuote($policyID)."
					AND Disabled = 0
			");
			if (!$sth) {
				$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
				return $server->protocol_response(PROTO_DB_ERROR);
			}
			# Loop with rows and build end policy
			while (my $row = $sth->fetchrow_hashref()) {
				# If defined, its to override
				if (defined($row->{'UseGreylisting'})) {
					$policy{'UseGreylisting'} = $row->{'UseGreylisting'};
				}
				if (defined($row->{'GreylistPeriod'})) {
					$policy{'GreylistPeriod'} = $row->{'GreylistPeriod'};
				}
				if (defined($row->{'Track'})) {
					$policy{'Track'} = $row->{'Track'};
				}
				if (defined($row->{'GreylistAuthValidity'})) {
					$policy{'GreylistAuthValidity'} = $row->{'GreylistAuthValidity'};
				}
				if (defined($row->{'GreylistUnAuthValidity'})) {
					$policy{'GreylistUnAuthValidity'} = $row->{'GreylistUnAuthValidity'};
				}
	
				if (defined($row->{'UseAutoWhitelist'})) {
					$policy{'UseAutoWhitelist'} = $row->{'UseAutoWhitelist'};
				}
				if (defined($row->{'AutoWhitelistPeriod'})) {
					$policy{'AutoWhitelistPeriod'} = $row->{'AutoWhitelistPeriod'};
				}
				if (defined($row->{'AutoWhitelistCount'})) {
					$policy{'AutoWhitelistCount'} = $row->{'AutoWhitelistCount'};
				}
				if (defined($row->{'AutoWhitelistPercentage'})) {
					$policy{'AutoWhitelistPercentage'} = $row->{'AutoWhitelistPercentage'};
				}
	
				if (defined($row->{'UseAutoBlacklist'})) {
					$policy{'UseAutoBlacklist'} = $row->{'UseAutoBlacklist'};
				}
				if (defined($row->{'AutoBlacklistPeriod'})) {
					$policy{'AutoBlacklistPeriod'} = $row->{'AutoBlacklistPeriod'};
				}
				if (defined($row->{'AutoBlacklistCount'})) {
					$policy{'AutoBlacklistCount'} = $row->{'AutoBlacklistCount'};
				}
				if (defined($row->{'AutoBlacklistPercentage'})) {
					$policy{'AutoBlacklistPercentage'} = $row->{'AutoBlacklistPercentage'};
				}
	
			} # while (my $row = $sth->fetchrow_hashref())
		} # foreach my $policyID (@{$sessionData->{'Policy'}->{$priority}})
	} # foreach my $priority (sort {$a <=> $b} keys %{$sessionData->{'Policy'}})

	# Check if we have a policy
	if (!%policy) {
		return CBP_CONTINUE;
	}

	# 
	# Check if we must use greylisting
	#
	if (defined($policy{'UseGreylisting'}) && $policy{'UseGreylisting'} ne "1") {
		return CBP_SKIP;
	}

	#
	# Check if we're whitelisted
	#
	my $sth = DBSelect("
		SELECT
			Source
		FROM
			greylisting_whitelist
		WHERE
			Disabled = 0
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
		return $server->protocol_response(PROTO_DB_ERROR);
	}
	# Loop with whitelist and calculate
	while (my $row = $sth->fetchrow_hashref()) {
		
		# Check format is SenderIP
		if ((my $address = $row->{'Source'}) =~ s/^SenderIP://i) {

			# Parse CIDR into its various peices
			my $parsedIP = parseCIDR($address);
			# Check if this is a valid cidr or IP
			if (ref $parsedIP eq "HASH") {

				# Check if IP is whitelisted
				if ($parsedIP->{'IP_Long'} >= $parsedIP->{'Network_Long'} && $parsedIP->{'IP_Long'} <= $parsedIP->{'Broadcast_Long'}) {
					$server->maillog("module=Greylisting, action=none, host=%s, from=%s, to=%s, reason=whitelisted",
							$sessionData->{'ClientAddress'},
							$sessionData->{'Helo'},
							$sessionData->{'Sender'},
							$sessionData->{'Recipient'});
					DBFreeRes($sth);
					return $server->protocol_response(PROTO_PASS);
				}
			} else {
				$server->log(LOG_ERR,"[GREYLISTING] Failed to parse address '$address' is invalid.");
				DBFreeRes($sth);
				return $server->protocol_response(PROTO_DATA_ERROR);
			}

		} else {
			$server->log(LOG_ERR,"[GREYLISTING] Whitelist entry '".$row->{'Source'}."' is invalid.");
			DBFreeRes($sth);
			return $server->protocol_response(PROTO_DATA_ERROR);
		}
	}


	#
	# Get tracking key used below
	#
	my $key = getKey($server,$policy{'Track'},$sessionData);
	if (!$key) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to get key from tracking spec '".$policy{'Track'}."'");
		return $server->protocol_response(PROTO_DATA_ERROR);
	}


	#
	# Check if we we must use auto-whitelisting and if we're auto-whitelisted
	#
	if (defined($policy{'UseAutoWhitelist'}) && $policy{'UseAutoWhitelist'} eq "1") {

		# Sanity check, no use doing the query to find out we don't have a period
		if (defined($policy{'AutoWhitelistPeriod'}) && $policy{'AutoWhitelistPeriod'} > 0) {
			my $sth = DBSelect("
				SELECT
					ID, LastSeen
				FROM
					greylisting_autowhitelist
				WHERE
					TrackKey = ".DBQuote($key)."
			");
			if (!$sth) {
				$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
				return $server->protocol_response(PROTO_DB_ERROR);
			}
			my $row = $sth->fetchrow_hashref();

			# Pull off first row
			if ($row) {

				# Check if we're within the auto-whitelisting period
				if ($sessionData->{'Timestamp'} - $row->{'LastSeen'} <= $policy{'AutoWhitelistPeriod'}) {

					my $sth = DBDo("
						UPDATE
							greylisting_autowhitelist
						SET
							LastSeen = ".DBQuote($sessionData->{'Timestamp'})."
						WHERE
							TrackKey = ".DBQuote($key)."
					");
					if (!$sth) {
						$server->log(LOG_ERR,"[GREYLISTING] Database update failed: ".cbp::dblayer::Error());
						return $server->protocol_response(PROTO_DB_ERROR);
					}

					$server->maillog("module=Greylisting, action=none, host=%s, from=%s, to=%s, reason=auto-whitelisted",
							$sessionData->{'ClientAddress'},
							$sessionData->{'Helo'},
							$sessionData->{'Sender'},
							$sessionData->{'Recipient'});

					return $server->protocol_response(PROTO_PASS);
				}
			} # if ($row)

		} else {  # if (defined($policy{'AutoWhitelistPeriod'}) && $policy{'AutoWhitelistPeriod'} > 0)
			$server->log(LOG_ERR,"[GREYLISTING] Resolved policy UseAutoWhitelist is set, but AutoWhitelistPeriod is not set or invalid");
			return $server->protocol_response(PROTO_DATA_ERROR);
		}
	} # if (defined($policy{'UseAutoWhitelist'}) && $policy{'UseAutoWhitelist'} eq "1")


	#
	# Check if we we must use auto-blacklisting and check if we're blacklisted
	#
	if (defined($policy{'UseAutoBlacklist'}) && $policy{'UseAutoBlacklist'} eq "1") {

		# Sanity check, no use doing the query to find out we don't have a period
		if (defined($policy{'AutoBlacklistPeriod'}) && $policy{'AutoBlacklistPeriod'} > 0) {
			my $sth = DBSelect("
				SELECT
					ID, Added
				FROM
					greylisting_autoblacklist
				WHERE
					TrackKey = ".DBQuote($key)."
			");
			if (!$sth) {
				$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
				return $server->protocol_response(PROTO_DB_ERROR);
			}
			my $row = $sth->fetchrow_hashref();

			# Pull off first row
			if ($row) {

				# Check if we're within the auto-blacklisting period
				if ($sessionData->{'Timestamp'} - $row->{'Added'} <= $policy{'AutoBlacklistPeriod'}) {

					$server->maillog("module=Greylisting, action=reject, host=%s, from=%s, to=%s, reason=auto-blacklisted",
							$sessionData->{'ClientAddress'},
							$sessionData->{'Helo'},
							$sessionData->{'Sender'},
							$sessionData->{'Recipient'});

					return ("REJECT","Greylisting in effect, sending server blacklisted");
				}

			} # if ($row)

		} else {  # if (defined($policy{'AutoBlacklistPeriod'}) && $policy{'AutoBlacklistPeriod'} > 0)
			$server->log(LOG_ERR,"[GREYLISTING] Resolved policy UseAutoBlacklist is set, but AutoBlacklistPeriod is not set or invalid");
			return $server->protocol_response(PROTO_DATA_ERROR);
		}
	} # if (defined($policy{'UseAutoBlacklist'}) && $policy{'UseAutoBlacklist'} eq "1")


	#
	# Update/Insert record into database
	#

	# Insert/update triplet in database
	$sth = DBDo("
		UPDATE 
			greylisting_tracking
		SET
			LastUpdate = ".DBQuote($sessionData->{'Timestamp'})."
		WHERE
			TrackKey = ".DBQuote($key)."
			AND Sender = ".DBQuote($sessionData->{'Sender'})."
			AND Recipient = ".DBQuote($sessionData->{'Recipient'})."
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Database update failed: ".cbp::dblayer::Error());
		return $server->protocol_response(PROTO_DB_ERROR);
	}
	# If we didn't update anything, insert
	if ($sth eq "0E0") {
		#
		# Check if we must blacklist the host for abuse ...
		#
		if (defined($policy{'UseAutoBlacklist'}) && $policy{'UseAutoBlacklist'} eq "1") {

			# Only proceed if we have a period
			if (defined($policy{'AutoBlacklistPeriod'}) && $policy{'AutoBlacklistPeriod'} > 0) {

				# Check if we have a count
				if (defined($policy{'AutoBlacklistCount'}) && $policy{'AutoBlacklistCount'} > 0) {
					# Work out time to check from...
					my $addedTime = $sessionData->{'Timestamp'} - $policy{'AutoBlacklistPeriod'};

					my $sth = DBSelect("
						SELECT
							Count(*) AS Count
						FROM
							greylisting_tracking
						WHERE
							TrackKey = ".DBQuote($key)."
							AND FirstSeen >= ".DBQuote($addedTime)."
					");
					if (!$sth) {
						$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
						return $server->protocol_response(PROTO_DB_ERROR);
					}
					my $row = $sth->fetchrow_hashref();


					# If count exceeds or equals blacklist count, nail the server
					if ($row->{'Count'} >= $policy{'AutoBlacklistCount'}) {
						# Start off as undef
						my $blacklist;

						# Check if we should blacklist this host
						if (defined($policy{'AutoBlacklistPercentage'}) && $policy{'AutoBlacklistPercentage'} > 0) {
							$sth = DBSelect("
								SELECT
									Count(*) AS Count
								FROM
									greylisting_tracking
								WHERE
									TrackKey = ".DBQuote($key)."
									AND FirstSeen >= ".DBQuote($addedTime)."
									AND Authenticated = 1
							");
							if (!$sth) {
								$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
								return $server->protocol_response(PROTO_DB_ERROR);
							}
							my $row2 = $sth->fetchrow_hashref();
					
							# Cannot divide by zero
							if ($row->{'Count'} > 0) {
								my $percentage = ( $row2->{'Count'} / $row->{'Count'} ) * 100;
								# If we meet the percentage of unauthenticated triplets, blacklist
								if ($percentage <= $policy{'AutoBlacklistPercentage'} ) {
									$blacklist = sprintf("Auto-blacklisted: Count/Required = %s/%s, Percentage/Threshold = %s/%s",
											$row->{'Count'}, $policy{'AutoBlacklistCount'},
											$percentage, $policy{'AutoBlacklistPercentage'});
								}
							}
						# This is not a percentage check
						} else {
							$blacklist = sprintf("Auto-blacklisted: Count/Required = %s/%s", $row->{'Count'}, $policy{'AutoBlacklistCount'});
						}
					
						# If we are to be listed, this is our reason
						if ($blacklist) {
							# Record blacklisting
							$sth = DBDo("
								INSERT INTO greylisting_autoblacklist
									(TrackKey,Added,Comment)
								VALUES
									(
										".DBQuote($key).",
										".DBQuote($sessionData->{'Timestamp'}).",
										".DBQuote($blacklist)."
									)
							");
							if (!$sth) {
								$server->log(LOG_ERR,"[GREYLISTING] Database insert failed: ".cbp::dblayer::Error());
								return $server->protocol_response(PROTO_DB_ERROR);
							}

							$server->maillog("module=Greylisting, action=reject, host=%s, from=%s, to=%s, reason=auto-blacklisted",
									$sessionData->{'ClientAddress'},
									$sessionData->{'Helo'},
									$sessionData->{'Sender'},
									$sessionData->{'Recipient'});

							return ("REJECT","Greylisting in effect, sending server blacklisted");
						}
					} # if ($row->{'Count'} >= $policy{'AutoBlacklistCount'})
				} # if (defined($policy{'AutoBlacklistCount'}) && $policy{'AutoBlacklistCount'} > 0)

			} else { # if (defined($policy{'AutoBlacklistPeriod'}) && $policy{'AutoBlacklistPeriod'} > 0)
				$server->log(LOG_ERR,"[GREYLISTING] Resolved policy UseAutoWBlacklist is set, but AutoBlacklistPeriod is not set or invalid");
				return $server->protocol_response(PROTO_DATA_ERROR);
			}
		}

		# Record triplet
		$sth = DBDo("
			INSERT INTO greylisting_tracking
				(TrackKey,Sender,Recipient,FirstSeen,LastUpdate)
			VALUES
				(
					".DBQuote($key).",
					".DBQuote($sessionData->{'Sender'}).",
					".DBQuote($sessionData->{'Recipient'}).",
					".DBQuote($sessionData->{'Timestamp'}).",
					".DBQuote($sessionData->{'Timestamp'})."
				)
		");
		if (!$sth) {
			$server->log(LOG_ERR,"[GREYLISTING] Database insert failed: ".cbp::dblayer::Error());
			return $server->protocol_response(PROTO_DB_ERROR);
		}

		$server->maillog("module=Greylisting, action=defer, host=%s, helo=%s, from=%s, to=%s, reason=greylisted",
				$sessionData->{'ClientAddress'},
				$sessionData->{'Helo'},
				$sessionData->{'Sender'},
				$sessionData->{'Recipient'});

		# Skip to rejection, if we using greylisting 0 seconds is highly unlikely to be a greylisitng period
		return $server->protocol_response(PROTO_DEFER,"451 4.7.1 Greylisting in effect, please come back later");

	# And just a bit of debug
	} else {
		$server->log(LOG_DEBUG,"[GREYLISTING] Updated greylisting triplet ('$key','".$sessionData->{'Sender'}."','".
				$sessionData->{'Recipient'}."') @ ".$sessionData->{'Timestamp'}."");
	}


	#
	# Retrieve record from database and check time elapsed
	#

	# Pull triplet and check
	$sth = DBSelect("
		SELECT
			FirstSeen,
			LastUpdate

		FROM
			greylisting_tracking

		WHERE
			TrackKey = ".DBQuote($key)."
			AND Sender = ".DBQuote($sessionData->{'Sender'})."
			AND Recipient = ".DBQuote($sessionData->{'Recipient'})."
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
		return $server->protocol_response(PROTO_DB_ERROR);
	}
	my $row = $sth->fetchrow_hashref();
	if (!$row) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to find triplet in database");
		return $server->protocol_response(PROTO_DB_ERROR);
	}

	# Check if we should greylist, or not
	my $timeElapsed = $row->{'LastUpdate'} - $row->{'FirstSeen'};
	if ($timeElapsed < $policy{'GreylistPeriod'}) {
		# Get time left, debug and return
		my $timeLeft = $policy{'GreylistPeriod'} - $timeElapsed;
		$server->maillog("module=Greylisting, action=defer, host=%s, helo=%s, from=%s, to=%s, reason=greylisted",
				$sessionData->{'ClientAddress'},
				$sessionData->{'Helo'},
				$sessionData->{'Sender'},
				$sessionData->{'Recipient'});

		return $server->protocol_response(PROTO_DEFER,"451 4.7.1 Greylisting in effect, please come back later");

	} else {
		# Insert/update triplet in database
		my $sth = DBDo("
			UPDATE 
				greylisting_tracking
			SET
				Authenticated = 1
			WHERE
				TrackKey = ".DBQuote($key)."
				AND Sender = ".DBQuote($sessionData->{'Sender'})."
				AND Recipient = ".DBQuote($sessionData->{'Recipient'})."
		");
		if (!$sth) {
			$server->log(LOG_ERR,"[GREYLISTING] Database update failed: ".cbp::dblayer::Error());
			return $server->protocol_response(PROTO_DB_ERROR);
		}

		#
		# Check if we must whitelist the host for being good
		#
		if (defined($policy{'UseAutoWhitelist'}) && $policy{'UseAutoWhitelist'} eq "1") {

			# Only proceed if we have a period
			if (defined($policy{'AutoWhitelistPeriod'}) && $policy{'AutoWhitelistPeriod'} > 0) {

				# Check if we have a count
				if (defined($policy{'AutoWhitelistCount'}) && $policy{'AutoWhitelistCount'} > 0) {
					my $addedTime = $sessionData->{'Timestamp'} - $policy{'AutoWhitelistPeriod'};

					my $sth = DBSelect("
						SELECT
							Count(*) AS Count
						FROM
							greylisting_tracking
						WHERE
							TrackKey = ".DBQuote($key)."
							AND FirstSeen >= ".DBQuote($addedTime)."
					");
					if (!$sth) {
						$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
						return $server->protocol_response(PROTO_DB_ERROR);
					}
					my $row = $sth->fetchrow_hashref();

					# If count exceeds or equals whitelist count, nail the server
					if ($row->{'Count'} >= $policy{'AutoWhitelistCount'}) {
						my $whitelist;

						# Check if we should whitelist this host
						if (defined($policy{'AutoWhitelistPercentage'}) && $policy{'AutoWhitelistPercentage'} > 0) {
							$sth = DBSelect("
								SELECT
									Count(*) AS Count
								FROM
									greylisting_tracking
								WHERE
									TrackKey = ".DBQuote($key)."
									AND FirstSeen >= ".DBQuote($addedTime)."
									AND Authenticated = 1
							");
							if (!$sth) {
								$server->log(LOG_ERR,"[GREYLISTING] Database query failed: ".cbp::dblayer::Error());
								return $server->protocol_response(PROTO_DB_ERROR);
							}
							my $row2 = $sth->fetchrow_hashref();
				
							# Cannot divide by zero
							if ($row->{'Count'} > 0) {
								my $percentage = ( $row2->{'Count'} / $row->{'Count'} ) * 100;
								# If we meet the percentage of unauthenticated triplets, whitelist
								if ($percentage >= $policy{'AutoWhitelistPercentage'} ) {
									$whitelist = sprintf("Auto-whitelisted: Count/Required = %s/%s, Percentage/Threshold = %s/%s",
											$row->{'Count'}, $policy{'AutoWhitelistCount'},
											$percentage, $policy{'AutoWhitelistPercentage'});
								}
							}
	
						} else {
							$whitelist = sprintf("Auto-whitelisted: Count/Required = %s/%s", $row->{'Count'}, $policy{'AutoWhitelistCount'});
						}
	
						# If we are to be listed, this is our reason
						if ($whitelist) {
							# Record whitelisting
							$sth = DBDo("
								INSERT INTO greylisting_autowhitelist
									(TrackKey,Added,LastSeen,Comment)
								VALUES
									(
										".DBQuote($key).",
										".DBQuote($sessionData->{'Timestamp'}).",
										".DBQuote($sessionData->{'Timestamp'}).",
										".DBQuote($whitelist)."
									)
							");
							if (!$sth) {
								$server->log(LOG_ERR,"[GREYLISTING] Database insert failed: ".cbp::dblayer::Error());
								return $server->protocol_response(PROTO_DB_ERROR);
							}
							$server->maillog("module=Greylisting, action=none, host=%s, from=%s, to=%s, reason=auto-whitelisted",
									$sessionData->{'ClientAddress'},
									$sessionData->{'Helo'},
									$sessionData->{'Sender'},
									$sessionData->{'Recipient'});

							return $server->protocol_response(PROTO_PASS);
						}
					} # if ($row->{'Count'} >= $policy{'AutoWhitelistCount'})
				} # if (defined($policy{'AutoWhitelistCount'}) && $policy{'AutoWhitelistCount'} > 0) 

			} else { # if (defined($policy{'AutoWhitelistPeriod'}) && $policy{'AutoWhitelistPeriod'} > 0)
				$server->log(LOG_ERR,"[GREYLISTING] Resolved policy UseAutoWWhitelist is set, but AutoWhitelistPeriod is not set or invalid");
				return $server->protocol_response(PROTO_DATA_ERROR);
			}
		}

		
		$server->maillog("module=Greylisting, action=none, host=%s, helo=%s, from=%s, to=%s, reason=authenticated",
				$sessionData->{'ClientAddress'},
				$sessionData->{'Helo'},
				$sessionData->{'Sender'},
				$sessionData->{'Recipient'});
				
		return $server->protocol_response(PROTO_PASS);
	}

	# We should never get here
	return CBP_ERROR;
}


# Get key from session
sub getKey
{
	my ($server,$track,$sessionData) = @_;


	my $res;


	# Split off method and splec
	my ($method,$spec) = ($track =~ /^([^:]+)(?::(\S+))?/);
	
	# Lowercase method & spec
	$method = lc($method);
	$spec = lc($spec) if (defined($spec));

	# Check TrackSenderIP
	if ($method eq "senderip") {
		my $key = getIPKey($spec,$sessionData->{'ClientAddress'});

		# Check for no key
		if (defined($key)) {
			$res = "SenderIP:$key";
		} else {
			$server->log(LOG_WARN,"[GREYLISTING] Unknown key specification in TrackSenderIP");
		}

	# Fall-through to catch invalid specs
	} else {
		$server->log(LOG_WARN,"[GREYLISTING] Invalid tracking specification '$track'");
	}


	return $res;
}


# Get key from session
sub getIPKey
{
	my ($spec,$ip) = @_;

	my $key;

	# Check if spec is ok...
	if ($spec =~ /^\/(\d+)$/) {
		my $mask = $1;

		# If we couldn't pull the mask, just return
		$mask = 32 if (!defined($mask));

		# Pull long for IP we going to test
		my $ip_long = ip_to_long($ip);
		# Convert mask to longs
		my $mask_long = bits_to_mask($mask);
		# AND with mask to get network addy
		my $network_long = $ip_long & $mask_long;
		# Convert to quad;/
		my $cidr_network = long_to_ip($network_long);

		# Create key
		$key = sprintf("%s/%s",$cidr_network,$mask);
	}

	return $key;
}


# Cleanup function
sub cleanup
{
	my ($server) = @_;

	# Get now
	my $now = time();

	#
	# Autowhitelist cleanups
	#
	
	# Get maximum AutoWhitelistPeriod
	my $sth = DBSelect("
		SELECt 
			MAX(AutoWhitelistPeriod) AS Period
		FROM 
			greylisting
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to query AutoWhitelistPeriod: ".cbp::dblayer::Error());
		return -1;
	}
	my $row = $sth->fetchrow_hashref();
	my $AWLPeriod = $row->{'Period'};

	# Bork if we didn't find anything of interest
	return if (!($AWLPeriod > 0));

	# Get start time
	$AWLPeriod = $now - $AWLPeriod;

	# Remove old whitelistings from database
	$sth = DBDo("
		DELETE FROM 
			greylisting_autowhitelist
		WHERE
			LastSeen <= ".DBQuote($AWLPeriod)."
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to remove old autowhitelist records: ".cbp::dblayer::Error());
		return -1;
	}


	#
	# Autoblacklist cleanups
	#
	
	# Get maximum AutoBlacklistPeriod
	$sth = DBSelect("
		SELECt 
			MAX(AutoBlacklistPeriod) AS Period
		FROM 
			greylisting
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to query AutoBlacklistPeriod: ".cbp::dblayer::Error());
		return -1;
	}
	$row = $sth->fetchrow_hashref();
	my $ABLPeriod = $row->{'Period'};

	# Bork if we didn't find anything of interest
	return if (!($ABLPeriod > 0));
	
	# Get start time
	$ABLPeriod = $now - $ABLPeriod;

	# Remove blacklistings from database
	$sth = DBDo("
		DELETE FROM 
			greylisting_autoblacklist
		WHERE
			Added <= ".DBQuote($ABLPeriod)."
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to remove old autoblacklist records: ".cbp::dblayer::Error());
		return -1;
	}
	
	#
	# Authenticated record cleanups
	#
	
	# Get maximum GreylistAuthValidity
	$sth = DBSelect("
		SELECt 
			MAX(GreylistAuthValidity) AS Period
		FROM 
			greylisting
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to query GreylistAuthValidity: ".cbp::dblayer::Error());
		return -1;
	}
	$row = $sth->fetchrow_hashref();
	my $AuthPeriod = $row->{'Period'};

	# Bork if we didn't find anything of interest
	return if (!($AuthPeriod > 0));

	# Get start time
	$AuthPeriod = $now - $AuthPeriod;

	# Remove old authenticated records from database
	$sth = DBDo("
		DELETE FROM 
			greylisting_tracking
		WHERE
			LastUpdate <= ".DBQuote($AuthPeriod)."
			AND Authenticated = 1
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to remove old authenticated records: ".cbp::dblayer::Error());
		return -1;
	}


	#
	# UnAuthenticated record cleanups
	#
	
	# Get maximum GreylistUnAuthValidity
	$sth = DBSelect("
		SELECt 
			MAX(GreylistUnAuthValidity) AS Period
		FROM 
			greylisting
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to query GreylistUnAuthValidity: ".cbp::dblayer::Error());
		return -1;
	}
	$row = $sth->fetchrow_hashref();
	my $UnAuthPeriod = $row->{'Period'};

	# Bork if we didn't find anything of interest
	return if (!($UnAuthPeriod > 0));

	# Get start time
	$UnAuthPeriod = $now - $UnAuthPeriod;

	# Remove old un-authenticated records info from database
	$sth = DBDo("
		DELETE FROM 
			greylisting_tracking
		WHERE
			LastUpdate <= ".DBQuote($UnAuthPeriod)."
			AND Authenticated = 0
	");
	if (!$sth) {
		$server->log(LOG_ERR,"[GREYLISTING] Failed to remove old un-authenticated records: ".cbp::dblayer::Error());
		return -1;
	}
}



1;
# vim: ts=4
