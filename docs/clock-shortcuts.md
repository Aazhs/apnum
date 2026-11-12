# Mirroring alarms into the macOS Clock app

apnum can copy its alarms into the Clock app so the Mac rings them even when apnum is not running. This needs one shortcut that you build once in the Shortcuts app. When "Mirror to Clock app" is on, apnum does not ring those alarms itself, so you never get a double alarm.

The exact action names and layout differ slightly between macOS versions. If a step below does not match what you see, pick the closest action with the same meaning.

## What the shortcut must do

Name it exactly **apnum Sync Alarms**. apnum runs it with this JSON as input:

```json
{"alarms": [
  {"hour": 7, "minute": 30, "label": "Gym [apnum]", "repeatDays": ["Monday", "Friday"]}
]}
```

`repeatDays` is empty for a one-time alarm. Every label ends with `[apnum]`. The shortcut deletes all Clock alarms whose label contains `[apnum]`, then adds the alarms it was given. Your own alarms (without the tag) are never touched, and syncing twice gives the same result.

## Build it

1. Open **Shortcuts**, press **+** to create a new shortcut and name it `apnum Sync Alarms`.
2. In the shortcut's details, set it to **Receive** input of type **Text** (or Any), from **Quick Actions / Services** as you prefer. This is the "Receive input" step.
3. Add **Get Dictionary from Input** (input: *Shortcut Input*). It turns the JSON text into a dictionary.
4. Add **Find Alarms** with the filter **Label contains** `[apnum]`.
5. Add **Delete Alarms** and give it the alarms found in step 4. If the Clock app asks for confirmation, turn off "Show When Run" on the action.
6. Add **Get Dictionary Value** for the key `alarms` from the dictionary of step 3.
7. Add **Repeat with Each** over that list. Inside the loop, for **Repeat Item**:
   1. **Get Dictionary Value** for `hour`, and again for `minute`, `label` and `repeatDays`.
   2. Build the time with **Adjust Date** or **Date**: take **Current Date**, then **Adjust Date** to set hour and minute from the values above (use *Get Time Between* style actions or a formatted text such as `hour:minute` converted with **Get Dates from Input** if your macOS version lacks a direct option).
   3. Add **Create Alarm** (called **Add Alarm** in some versions) with that time, the label value as **Label**, and the days from `repeatDays` as **Repeat**. If the action only accepts fixed day toggles, use **If** actions on `repeatDays` contains each weekday name.
8. Run it once from the Shortcuts app with some test input to confirm that alarms appear in Clock and that running it again does not create duplicates. The first run may ask for permission to control Clock; allow it.

## Check it in apnum

Turn on "Mirror to Clock app" in apnum's alarm settings, or call the `alarm.mirror.sync` tool. If the shortcut is missing or named differently, apnum reports an error that points back to this page, and your alarms still work in apnum.
