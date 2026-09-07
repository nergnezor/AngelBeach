// HUD placeholder - score display is handled via UMG or future widget implementation.
//
// This used to also draw the Android action buttons (Jump/Pass/Set/Spike, drawn
// with AHUD::DrawRect/DrawText and answered via the hit box system — script in
// this fork cannot read the raw touch stream at all, see git history). They were
// removed: contact already happens automatically on arm collision (see
// Ball.as::CheckPlayerCollision), so the buttons only ever nudged which of
// Pass/Set/Spike the next contact used, and playtesting found touch players
// never reached for them. Movement is unaffected — it was always the engine's
// own virtual joystick overlay, configured in Config/DefaultInput.ini, which
// needs no HUD/script at all.
//
// GM is wired by ABeachVolleyballGameMode.SpawnActors (there is no
// BlueprintCallable "get the game mode" on UWorld/AActor in this fork — GameMode
// pushes the reference down to whoever needs it, same as for ABall and
// AHumanPlayer).

class ABeachVolleyballHUD : AHUD
{
	ABeachVolleyballGameMode GM;
}
