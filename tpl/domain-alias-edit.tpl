[% INCLUDE header.tpl %]
    <div id="main">
    	<div id="edit_form">
    	<form name="create_domain" method="POST">
    	<input type="hidden" name="rm" value="update_domain_alias" />
    	<table>
    		<tr>
    			<td colspan="2">
    				<h3>Modify a domain alias</h3>
    			</td>
    		</tr>
    		<tr>
				<td>Alias-Domain:</td>
				<td>[% domain_name %]</td>
			</tr>
			<tr>
				<td>Target:</td>
				<td>
					[% FOREACH line IN domains %]
						[% IF loop.first %]
						<select name="target">
						[% END %]
							<option value="[% line.id %]"[% IF line.id == target %] selected[% END %]>[% line.name %]</option>
						[% IF loop.last %]
						</select>
						[% END %]
					[% END %]
				</td>
			</tr>
			<tr>
				<td>Enabled:</td>
				<td><input type="checkbox" name="is_active"[% IF is_active %] checked[% END %] /></td>
			</tr>
			<tr>
				<td colspan="2" align="center">
					<input class="button" type="submit" name="submit" value="Modify Domain" />
					<input type="hidden" name="domain_alias_id" value="[% domain_alias_id %]" />
				</td>
			</tr>
		</table>
		</form>
		</div>
    </div>
[% INCLUDE footer.tpl %]