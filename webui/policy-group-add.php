<?php
# Policy group add
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


include_once("includes/header.php");
include_once("includes/footer.php");
include_once("includes/db.php");



$db = connect_db();



printHeader(array(
		"Tabs" => array(
			"Back to groups" => "policy-group-main.php",
		),
));


if ($_POST['action'] == "add")  {
?>
	<h1>Add Policy Group</h1>
<?php
?>
		<form method="post" action="policy-group-add.php">
			<input type="hidden" name="action" value="add2" />
			<input type="hidden" name="policy_group_id" value="<?php echo $_POST['policy_group_id'] ?>" />
			<table class="entry">
				<tr>
					<td class="entrytitle">Name</td>
					<td><input type="text" name="policy_group_name" /></td>
				</tr>
				<tr>
					<td class="entrytitle">Comment</td>
					<td><textarea name="policy_group_comment"></textarea></td>
				</tr>
				<tr>
					<td colspan="2">
						<input type="submit" />
					</td>
				</tr>
			</table>
		</form>
<?php
	
	
	
# Check we have all params
} elseif ($_POST['action'] == "add2") {
?>
	<h1>Policy Group Add Results</h1>

<?php

	$stmt = $db->prepare("INSERT INTO policy_groups (Name,Comment,Disabled) VALUES (?,?,1)");
	
	$res = $stmt->execute(array(
		$_POST['policy_group_name'],
		$_POST['policy_group_comment']
	));
	if ($res) {
?>
		<div class="notice">Policy group created</div>
<?php
	} else {
?>
		<div class="warning">Failed to create policy group</div>
<?php
	}



} else {
?>
	<div class="warning">Invalid invocation</div>
<?php
}


printFooter();


# vim: ts=4
?>
