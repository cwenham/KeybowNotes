#!/usr/bin/osascript
-- Helper for spike 2. Usage: notes-append-test.applescript (read|info|append) "<note name>"

on run argv
	if (count of argv) < 2 then error "Usage: notes-append-test.applescript (read|info|append) <note name>"
	set mode to item 1 of argv
	set noteName to item 2 of argv

	tell application "Notes"
		set matches to every note whose name is noteName
		if (count of matches) is 0 then error "No note named \"" & noteName & "\""
		if (count of matches) > 1 then error "More than one note named \"" & noteName & "\" — rename or delete the extras"
		set theNote to item 1 of matches
		if password protected of theNote then error "The note is locked; unlock it or use another"

		if mode is "read" then
			return body of theNote
		else if mode is "info" then
			-- Fetch each value into a local variable first. Compound expressions like
			-- "name of container of theNote" are sent to Notes to evaluate, and it
			-- returns something that won't coerce to text (error -1700).
			set noteID to id of theNote
			set modDate to modification date of theNote
			set noteTextValue to plaintext of theNote

			set folderName to "(unavailable)"
			try
				set theFolder to container of theNote
				set folderName to name of theFolder
			end try
			set attachmentCount to "(unavailable)"
			try
				set theAttachments to attachments of theNote
				set attachmentCount to (count theAttachments) as text
			end try

			return "id: " & noteID & linefeed & ¬
				"folder: " & folderName & linefeed & ¬
				"attachments: " & attachmentCount & linefeed & ¬
				"characters: " & ((count characters of noteTextValue) as text) & linefeed & ¬
				"modified: " & (modDate as text)
		else if mode is "append" then
			set stamp to (current date) as text
			set currentBody to body of theNote
			set body of theNote to currentBody & "<div><b>Appended by KeybowNotes spike</b> at " & stamp & "</div>"
			show theNote
			activate
			return "appended"
		else
			error "Unknown mode: " & mode
		end if
	end tell
end run
