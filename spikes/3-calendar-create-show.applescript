#!/usr/bin/osascript
-- Spike 3: create an event, then show it in Calendar for editing. Is that good enough UX?
-- Usage: 3-calendar-create-show.applescript                  (lists your calendars)
--        3-calendar-create-show.applescript "<calendar name>"  (creates a test event tomorrow 10:00)

on run argv
	if (count of argv) is 0 then
		tell application "Calendar" to set calNames to name of every calendar
		set AppleScript's text item delimiters to linefeed
		return "Pass one of these calendar names:" & linefeed & (calNames as text)
	end if
	set calName to item 1 of argv

	set startDate to (current date) + 1 * days
	set time of startDate to 10 * hours
	set endDate to startDate + 30 * minutes

	set t0 to current date
	tell application "Calendar"
		tell calendar calName
			set newEvent to make new event at end of events with properties ¬
				{summary:"KeybowNotes spike event", start date:startDate, end date:endDate, ¬
					location:"Desk", description:"Created by KeybowNotes spike 3. Safe to delete.", ¬
					url:"https://example.com/keybownotes"}
		end tell
		show newEvent
		activate
		set eventUID to uid of newEvent
	end tell
	set elapsed to (current date) - t0

	return "Created and showed event " & eventUID & " in " & elapsed & "s." & linefeed & ¬
		"Try editing it, then delete it yourself in Calendar when done."
end run
