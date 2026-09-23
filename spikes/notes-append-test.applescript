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
			return "id: " & (id of theNote) & linefeed & ¬
				"folder: " & (name of container of theNote) & linefeed & ¬
				"attachments: " & (count of attachments of theNote) & linefeed & ¬
				"modified: " & ((modification date of theNote) as text)
		else if mode is "append" then
			set stamp to (current date) as text
			set body of theNote to (body of theNote) & "<div><b>Appended by KeybowNotes spike</b> at " & stamp & "</div>"
			show theNote
			activate
			return "appended"
		else
			error "Unknown mode: " & mode
		end if
	end tell
end run
