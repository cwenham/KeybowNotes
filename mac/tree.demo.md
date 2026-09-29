KeybowNotes demo tree — made-up people, projects and places, to try the keys
with. Change it in the tree editor (Edit Tree… in the menu bar's menu), or in
any text editor: KeybowNotes picks up the change when the file is saved.

1. Work [colour: 0060ff]
   1. Code
      1. Website [type: app.open, app: Visual Studio Code, bundleId: com.microsoft.VSCode]
      2. Firmware [type: app.open, app: Thonny]
   2. Schedule [Calendar]
      1. Meeting [5 min alert, @when]
      2. Deployment [20 min alert, @when]
   3. Contact
      1. Message [Messages]
         1. Alex Example
         2. Sam Sample
      2. Mail [Mail]
         1. Alex Example
         2. Sam Sample
   4. Notes
      1. Standup [standup.md]
      2. Work log [append, find.byName: "Work log — week {{isoWeek}}"]
2. Home [colour: 00c060]
   1. Groceries [Reminders, list: Shopping]
      1. Milk
      2. Bread
      3. Eggs
      4. Coffee
   2. Appointment [Calendar, @when]
3. Writing [colour: ff8c00]
   1. Characters
      1. The Detective
      2. The Witness
   2. Scenes
4. Ideas [colour: b060ff]
   1. Inventions
   2. Stories
   3. Wild speculation

# row 2
1. Check-in [colour: 00c8c8, append, find.byName: "Check-ins — {{date:MMMM yyyy}}", folder: Journal]
   1. Mood [@rating]
   2. Energy [@rating]
   3. Focus [@rating]
2. Capture [colour: ffd000]
   1. Clipboard
      1. To inbox [Notes, folder: Inbox, title: "{{clipboard|Clipping}} — {{time}}"]
      2. As task [Reminders, title: "{{clipboard|Task}}"]
   2. Quick note
      1. Blank [Notes, folder: Inbox, title: "Note — {{datetime}}"]

# row 3
1. Timer [colour: ff6030, Reminders, title: "Timer: {{leaf}}"]
   1. 5 min [due: +5m]
   2. 15 min [due: +15m]
   3. 25 min [due: +25m]
   4. 50 min [due: +50m]
2. Open [colour: d0d0d0, type: app.open]
   1. Notes [app: Notes]
   2. Calendar [app: Calendar]
   3. Mail [app: Mail]

# bottom
1. Home [colour: ff40c0, type: shortcut, name: "{{level2}} {{level3}} {{leaf}}"]
   1. Lights
      1. Kitchen
         1. On
         2. Off
         3. Dim
      2. Lounge
         1. On
         2. Off
         3. Movie
   2. Heating
      1. Upstairs
         1. Warm
         2. Cool
         3. Off
      2. Downstairs
         1. Warm
         2. Cool
         3. Off
2. Journal [colour: ff5050, append, find.byName: "Journal — {{date:MMMM yyyy}}", folder: Journal]

# list when
1. Today [when: today]
2. Tomorrow [when: tomorrow]
3. Next week [when: next week]
4. Next month [when: next month]

# list rating
1. Great
2. Good
3. Meh
4. Rough

# contacts
- Alex Example [phone: +15550100, email: alex@example.com]
- Sam Sample [phone:, email: sam@example.com]

# projects
- Website [path: ~/Code/website]
- Firmware [path: ~/Code/firmware]

# defaults
- colour: 202020
- commitDelayMs: 1200
- idleTimeoutMs: 12000
- longPressCancelMs: 1500
- dates.todayOffsetMinutes: 30
- dates.defaultTime: 09:00
