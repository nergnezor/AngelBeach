// Draws score and FPS with AHUD::DrawText (no textures, no UMG asset — a
// hand-authored widget blueprint would be gitignored per CLAUDE.md's "no binary
// assets in git" rule and missing on a fresh clone), and on mobile a light-graphics
// toggle button answering the B key's job (AHumanPlayer::OnLightGraphics) for
// touch, which has no key to press.
//
// This used to also draw the Android action buttons (Jump/Pass/Set/Spike, drawn
// with AHUD::DrawRect/DrawText and answered via the hit box system — script in
// this fork cannot read the raw touch stream at all, see git history). They were
// removed: contact already happens automatically on arm collision (see
// Ball.as::CheckPlayerCollision), so the buttons only ever nudged which of
// Pass/Set/Spike the next contact used, and playtesting found touch players
// never reached for them. Movement is unaffected — it was always the engine's
// own virtual joystick overlay, configured in Config/DefaultInput.ini, which
// needs no HUD/script at all. The graphics toggle button below reuses that same
// hit box system and the same bottom-right corner spot, which the removed
// cluster's own comment already worked out is clear of the joystick (its right
// stick sits around three-quarters across the screen).
//
// GM is wired by ABeachVolleyballGameMode.SpawnActors (there is no
// BlueprintCallable "get the game mode" on UWorld/AActor in this fork — GameMode
// pushes the reference down to whoever needs it, same as for ABall and
// AHumanPlayer).

class ABeachVolleyballHUD : AHUD
{
	ABeachVolleyballGameMode GM;

	// AHUD::DrawHUD is not handed DeltaSeconds, so the framerate is measured in
	// Tick (every game frame) and only read back in DrawHUD (every render frame).
	private float SmoothedFPS = 0.0f;

	// Exponential-moving-average weight for the readout: low enough that one
	// hitched frame doesn't make the number unreadable, high enough that it
	// still tracks a real fps change within well under a second.
	private const float FPSSmoothing = 0.1f;

	private const float HUDMargin = 24.0f;
	private const float HUDLineHeight = 28.0f;
	private const float FPSColumnWidth = 100.0f;

	private const float GfxButtonWidth = 160.0f;
	private const float GfxButtonHeight = 56.0f;

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (DeltaTime <= 0.0f)
			return; // paused / first frame — would divide by ~0

		float InstantFPS = 1.0f / DeltaTime;
		SmoothedFPS = (SmoothedFPS <= 0.0f) ? InstantFPS
			: Math::Lerp(SmoothedFPS, InstantFPS, FPSSmoothing);
	}

	UFUNCTION(BlueprintOverride)
	void DrawHUD(int SizeX, int SizeY)
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS != nullptr)
		{
			DrawText(GS.GetScoreString(), FLinearColor(1.0f, 1.0f, 1.0f, 0.9f),
				HUDMargin, HUDMargin, nullptr, 1.5f, false);
			DrawText(GS.GetSetsString(), FLinearColor(0.8f, 0.8f, 0.8f, 0.9f),
				HUDMargin, HUDMargin + HUDLineHeight, nullptr, 1.0f, false);
		}

		FString FPSText = "FPS " + int(SmoothedFPS + 0.5f); // +0.5 rounds, no bound Math::Round
		DrawText(FPSText, FLinearColor(0.6f, 1.0f, 0.6f, 0.9f),
			float(SizeX) - HUDMargin - FPSColumnWidth, HUDMargin, nullptr, 1.0f, false);

		if (GM != nullptr && GM.IsMobilePlatform())
			DrawGraphicsToggleButton(SizeX, SizeY);
	}

	private void DrawGraphicsToggleButton(int SizeX, int SizeY)
	{
		FVector2D TopLeft = FVector2D(
			float(SizeX) - HUDMargin - GfxButtonWidth,
			float(SizeY) - HUDMargin - GfxButtonHeight);
		FVector2D Size = FVector2D(GfxButtonWidth, GfxButtonHeight);

		DrawRect(FLinearColor(0.0f, 0.0f, 0.0f, 0.35f), TopLeft.X, TopLeft.Y, Size.X, Size.Y);

		// Names the mode you'll SWITCH TO, not the one you're in — same convention
		// as a light switch showing "on".
		FString Label = GM.bLightGraphics ? "Full graphics" : "Light graphics";
		DrawText(Label, FLinearColor(1.0f, 1.0f, 1.0f, 0.9f),
			TopLeft.X + 12.0f, TopLeft.Y + 18.0f, nullptr, 1.0f, false);

		// Consumes the touch so a tap on the button never also reaches the world.
		AddHitBox(TopLeft, Size, n"BtnGraphics", true, 0);
	}

	UFUNCTION(BlueprintOverride)
	void HitBoxClick(FName BoxName)
	{
		if (BoxName == n"BtnGraphics" && GM != nullptr)
			GM.ToggleLightGraphics();
	}
}
