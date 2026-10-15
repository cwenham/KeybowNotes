KeybowNotes showcase — every kind of key, with made-up people, places and
things. The pictures in the README are of this tree. Copy what you like into
your own: Edit Tree… in the menu bar, or any text editor.

1. Work [colour: 0060ff]
   1. Meeting [Calendar, 10 min alert, duration: 45m]
      1. Today
      2. Tomorrow
      3. Next week
      4. Friday
   2. Notes
      1. Standup [standup.md]
      2. Work log [append, find.byName: "Work log — week {{isoWeek}}"]
      3. Ideas [folder: Ideas]
   3. People
      1. Message [Messages]
         1. Alex Example
         2. Sam Sample
      2. Mail [Mail, subject: "Quick question"]
         1. Alex Example
         2. Sam Sample
      3. Call [Call]
         1. Alex Example
         2. Sam Sample
      4. FaceTime [FaceTime]
         1. Alex Example
         2. Sam Sample
   4. Meetings
      1. Join [Join]
      2. Minute it [Add to Event, text: "**{{time}}** — {{selection}}"]
      3. Done [Done]
      4. Remind me [Reminders]
         1. In 25 minutes [due: +25m]
         2. Tomorrow morning [due: tomorrow 9:00]
2. Writing [colour: 00c060]
   1. Summarise [Insert, text: "{{#ai}}Summarise in one line: {{selection}}{{/ai}}"]
   2. Tidy up [Direct Insert, text: "{{#ai}}Fix the spelling and grammar, changing nothing else: {{selection}}{{/ai}}"]
   3. Quote it [Insert, text: "“{{selection}}”"]
   4. Snippets [Copy]
      1. Kind regards
      2. Address [text: "1 High Street\nSmalltown"]
      3. Today [text: "{{date:d MMMM yyyy}}"]
      4. Unpaid [unpaid.md]
3. Look up [colour: ff8c00]
   1. Explain [Display, text: "{{#ai}}Explain briefly: {{selection}}{{/ai}}", button: okCancel, ok: Notes, ok.folder: Explained, ok.title: "{{selection}}"]
   2. Search [Ask, text: "Search the web for", initial: "{{selection|}}", ok: Link, ok.url: "https://duckduckgo.com/?q={{answer}}"]
   3. Web [Browser]
      1. Search selected [url: "https://duckduckgo.com/?q={{selection}}"]
      2. Swift docs [https://www.swift.org/documentation/]
      3. Map it [Maps, query: "{{selection}}"]
      4. Coffee [Maps]
   4. Quote [Display, text: "{{quote file=quotes.md}}", fade: 20 sec]
4. Play [colour: b060ff]
   1. Music [Music]
      1. Focus
      2. Party [shuffle: true]
      3. Kind of Blue [album: Kind of Blue, artist: Miles Davis]
   2. Timer [Timer]
      1. 5 Minutes
      2. 25 Minutes
      3. Tea [duration: 4 min]
   3. Stopwatch [Stopwatch]
      1. Start
      2. Stop
      3. Lap
      4. Reset
   4. Open
      1. Terminal [type: app.open, app: Terminal]
      2. Website [type: app.open, app: TextEdit, open: ~/Code/website/README.md]
      3. Morning [type: shortcut, name: Morning routine]
      4. Inbox [things:///show?id=inbox]

# row 2 [pages]
1. Windows [colour: f0a020, Window]
   1. Left
   2. Right
   3. Top left
   4. Top right
   5. Full
   6. Next screen
   7. Bottom left
   8. Bottom right
2. Mac [colour: 40a0ff]
   1. Louder [Volume]
   2. Quieter [Volume]
   3. Mute [Volume]
   4. Mic [Microphone]
   5. Brighter [Brightness]
   6. Dimmer [Brightness]
   7. Night Shift [Night Shift]
   8. Dark [Dark Mode]
3. More [colour: 9070ff]
   1. Wi-Fi [Wi-Fi]
   2. Bluetooth [Bluetooth]
   3. Awake [Stay Awake]
   4. Bedtime [Focus]
   5. All windows [Exposé]
   6. App windows [Exposé]
   7. Desktop [Exposé]

# row 3
1. Home [colour: ff40c0, Home]
   1. Desk lamp [entity: light.desk_lamp]
   2. Reading [entity: light.desk_lamp, brightness: 40, kelvin: 2700]
   3. Warmer [entity: climate.hallway, temperature: 21.5]
   4. Evening [entity: scene.evening]
2. Outside [colour: 30c0ff, Display, text: "It's {{home.sensor.outdoor_temperature.text|unknown}} outside"]

# bottom
1. Check-in [colour: 00c8c8, append, find.byName: "Check-ins — {{date:MMMM yyyy}}", folder: Journal]
   1. Mood [@rating]
   2. Energy [@rating]
   3. Focus [@rating]
2. Capture [colour: ffd000]
   1. Clipboard
      1. To inbox [Notes, folder: Inbox, title: "{{clipboard|Clipping}} — {{time}}"]
      2. As task [Reminders, title: "{{clipboard|Task}}"]
   2. Jot [Ask, text: "A note for the inbox", multiline: true, ok: append, ok.find.byName: Inbox, ok.entry: "{{answer}}"]

# keypad Desk [RGB Keypad]
1. Stopwatch [colour: ff6030, Stopwatch]
   1. Start
   2. Stop
   3. Lap
   4. Reset
2. Windows [colour: f0a020, Window]
   1. Left
   2. Right
   3. Full
   4. Next screen

# list rating
1. Great
2. Good
3. Meh
4. Rough

# contacts
- Alex Example [phone: +15550100, email: alex@example.com]
- Sam Sample [phone: +15550101, email: sam@example.com]

# defaults
- colour: 202020
- commitDelayMs: 1200
