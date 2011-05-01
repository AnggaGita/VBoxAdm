[% INCLUDE header.tpl %]
    <div id="main">
		[% FOREACH line IN blacklist %]
		[% IF loop.first %]
		<table class="datatable">
			<thead>
			<tr>
				<th>[% "Recipient" | l10n %]</th>
				<th>[% "Sender" | l10n %]</th>
				<th>[% "Sent at" | l10n %]</th>
			</tr>
			</thead>
			<tbody>
		[% END %]
			<tr class="[% loop.parity %] [% IF line.is_active %]enabled[% ELSE %]disabled[% END %]">
				<td>
					[% line.on_vacation | highlight(search) %]
				</td>
				<td>
					[% line.notified | highlight(search) %]
				</td>
				<td>
					[% line.notified_at %]
				</td>
			</tr>
		[% IF loop.last %]
		</tbody>
		<tfoot>
		</tfoot>
		</table>
		[% END %]
		[% END %]
		<br />
    </div>
[% INCLUDE footer.tpl %]
