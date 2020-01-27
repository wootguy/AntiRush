# Anti Rush
This doesn't work for all maps, but could be improved in the future. All the official campaigns (HLSP, Op4, BS) work with this plugin.

The way it works is by searching for a game_end or trigger_changelevel entity and then replacing whatever triggers it with new ents for counting players. Once enough players have reached the level change or pressed the end-level button the map changes.

You can configure the plugin with these cvars:

```
as_command rush.percent 51
as_command rush.delay 5
as_command rush.disabled 0
as_command rush.mode 1
```
`rush.percent` is the percentage of players needed to finish the map ("51" = 51%)  
`rush.delay` is the amount of time before changing maps after enough players have finished ("5" = 5 seconds. Minimum is 3.)  
`rush.disabled` disables anti-rush for the current map if set to "1" (can't be changed mid-map).  
`rush.mode` controls when to start the level change timer (`rush.delay`).  
- 0 = Timer starts when `rush.percent` of players finish. Instant change when 100% finish.
- 1 (default) = Timer starts when first player finishes. Instant change when `rush.percent` of players finish.

Players can say or type `.rush` in console to check how many more players are needed to finish the level. `.rush version` displays the plugin version.
