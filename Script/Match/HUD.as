// HUD placeholder - score display is handled via UMG or future widget implementation.
//
// The one thing actually drawn here is the Android on-screen control scheme: a
// drag joystick (movement) and four tap buttons (Jump/Pass/Set/Spike), the touch
// equivalent of the WASD + Space/E/LeftShift/F bindings in DefaultInput.ini.
// Desktop/gamepad players never see this — AHumanPlayer already plays itself as
// AI until real input arrives, and GM.IsMobilePlatform() keeps it off everywhere
// that isn't Android/iOS. Drawn with AHUD::DrawRect/DrawText (no textures) to
// match the "no binary assets in git" rule in CLAUDE.md.
//
// THIS CLASS DRAWS AND HIT-TESTS; IT DOES NOT RECEIVE INPUT. Touches arrive on
// AHumanPlayer's input component (BindTouch) and are forwarded into
// HandleTouchBegin/Moved/End below. Binding APlayerController.OnInputTouchBegin
// here instead was the bug that shipped dead controls: that delegate is AActor's
// "this actor was touched" event, needs collision, and never fires for a
// PlayerController — so the buttons drew correctly and did nothing.
//
// GM and the pawn's TouchHUD back-reference are both wired by
// ABeachVolleyballGameMode.SpawnActors (there is no BlueprintCallable "get the
// game mode" on UWorld/AActor in this fork — GameMode pushes the reference down
// to whoever needs it, same as it does for ABall and AHumanPlayer).

class ABeachVolleyballHUD : AHUD
{
	ABeachVolleyballGameMode GM;

	// Updated every DrawHUD; touch handling reuses the last known size rather
	// than querying the viewport again.
	private float ScreenSizeX = 1280.0f;
	private float ScreenSizeY = 720.0f;

	// Which finger is driving the joystick, tracked as a plain int: the
	// ETouchIndex::Type spelling only resolves as a UFUNCTION parameter matching
	// a native delegate, so the pawn casts to int at the boundary.
	private bool bMoveTouchActive = false;
	private int MoveFingerIndex = 0;
	private FVector2D MoveOrigin = FVector2D(0.0f, 0.0f);
	private FVector2D JoystickKnobOffset = FVector2D(0.0f, 0.0f);

	private const float JoystickRadius = 100.0f;
	private const float JoystickDeadZone = 10.0f;
	private const float ButtonRadius = 48.0f;

	UFUNCTION(BlueprintOverride)
	void DrawHUD(int SizeX, int SizeY)
	{
		if (GM == nullptr || !GM.IsMobilePlatform())
			return;

		ScreenSizeX = float(SizeX);
		ScreenSizeY = float(SizeY);

		DrawJoystick();
		DrawButton(JumpCenter(),  "Jump");
		DrawButton(PassCenter(),  "Pass");
		DrawButton(SetCenter(),   "Set");
		DrawButton(SpikeCenter(), "Spike");
	}

	// ---- Layout (screen space, anchored to the bottom corners) -------------

	private FVector2D ClusterCenter() const
	{
		return FVector2D(ScreenSizeX - 200.0f, ScreenSizeY - 220.0f);
	}

	private FVector2D JumpCenter()  const { return ClusterCenter() + FVector2D(0.0f, 90.0f); }
	private FVector2D PassCenter()  const { return ClusterCenter() + FVector2D(-90.0f, 0.0f); }
	private FVector2D SpikeCenter() const { return ClusterCenter() + FVector2D(90.0f, 0.0f); }
	private FVector2D SetCenter()   const { return ClusterCenter() + FVector2D(0.0f, -90.0f); }

	private FVector2D JoystickIdleBase() const
	{
		return FVector2D(160.0f, ScreenSizeY - 160.0f);
	}

	// ---- Drawing -------------------------------------------------------------

	private void DrawJoystick()
	{
		FVector2D Base = bMoveTouchActive ? MoveOrigin : JoystickIdleBase();

		DrawRect(FLinearColor(0.0f, 0.0f, 0.0f, 0.25f),
			Base.X - JoystickRadius, Base.Y - JoystickRadius,
			JoystickRadius * 2.0f, JoystickRadius * 2.0f);

		FVector2D Knob = Base + JoystickKnobOffset;
		float KnobRadius = 34.0f;
		FLinearColor KnobColor = bMoveTouchActive
			? FLinearColor(1.0f, 1.0f, 1.0f, 0.55f)
			: FLinearColor(1.0f, 1.0f, 1.0f, 0.30f);
		DrawRect(KnobColor, Knob.X - KnobRadius, Knob.Y - KnobRadius, KnobRadius * 2.0f, KnobRadius * 2.0f);
	}

	// No GetTextSize on this HUD build, so labels aren't pixel-centred — just
	// nudged by a rough half-width guess. Cosmetic only; doesn't affect hit-testing.
	private void DrawButton(FVector2D Center, FString Label)
	{
		DrawRect(FLinearColor(0.0f, 0.0f, 0.0f, 0.30f),
			Center.X - ButtonRadius, Center.Y - ButtonRadius,
			ButtonRadius * 2.0f, ButtonRadius * 2.0f);

		float ApproxHalfWidth = Label.Len() * 4.0f;
		DrawText(Label, FLinearColor(1.0f, 1.0f, 1.0f, 0.85f),
			Center.X - ApproxHalfWidth, Center.Y - 8.0f, nullptr, 1.0f, false);
	}

	// ---- Touch handling (called by AHumanPlayer's BindTouch handlers) ------

	void HandleTouchBegin(int FingerIndex, FVector2D Touch)
	{
		AHumanPlayer Pawn = (GM != nullptr) ? GM.HumanPawn : nullptr;
		if (Pawn == nullptr)
			return;

		// Left half of the screen: claim this finger for the movement joystick,
		// with the stick re-centred wherever the thumb landed (first finger there
		// wins, so a button tap by the other hand can't steal movement).
		if (Touch.X < ScreenSizeX * 0.5f)
		{
			if (!bMoveTouchActive)
			{
				bMoveTouchActive = true;
				MoveFingerIndex = FingerIndex;
				MoveOrigin = Touch;
				JoystickKnobOffset = FVector2D(0.0f, 0.0f);
				Pawn.TouchMove(0.0f, 0.0f);
			}
			return;
		}

		// Right half: hit-test the four action buttons.
		if ((Touch - JumpCenter()).Size() <= ButtonRadius)
			Pawn.TouchJump();
		else if ((Touch - PassCenter()).Size() <= ButtonRadius)
			Pawn.TouchPass();
		else if ((Touch - SetCenter()).Size() <= ButtonRadius)
			Pawn.TouchSet();
		else if ((Touch - SpikeCenter()).Size() <= ButtonRadius)
			Pawn.TouchSpike();
	}

	void HandleTouchMoved(int FingerIndex, FVector2D Touch)
	{
		if (!bMoveTouchActive || FingerIndex != MoveFingerIndex)
			return;

		AHumanPlayer Pawn = (GM != nullptr) ? GM.HumanPawn : nullptr;
		if (Pawn == nullptr)
			return;

		FVector2D Delta = Touch - MoveOrigin;
		float Len = Delta.Size();
		if (Len < JoystickDeadZone)
		{
			JoystickKnobOffset = FVector2D(0.0f, 0.0f);
			Pawn.TouchMove(0.0f, 0.0f);
			return;
		}

		float ClampedLen = Math::Min(Len, JoystickRadius);
		FVector2D Dir = Delta / Len;
		JoystickKnobOffset = Dir * ClampedLen;

		float Magnitude = ClampedLen / JoystickRadius;
		// The match camera looks down world +X (see ABeachVolleyballCamera), with
		// +Y as its screen-right — the same axes AxisForward/AxisRight already use
		// for WASD (see AHumanPlayer.MovePlayer) — so dragging up/right on screen
		// needs no camera-relative conversion, just a screen-Y flip (screen Y
		// grows downward).
		float Forward = -Dir.Y * Magnitude;
		float Right   =  Dir.X * Magnitude;
		Pawn.TouchMove(float32(Forward), float32(Right));
	}

	void HandleTouchEnd(int FingerIndex, FVector2D Touch)
	{
		if (!bMoveTouchActive || FingerIndex != MoveFingerIndex)
			return;

		bMoveTouchActive = false;
		JoystickKnobOffset = FVector2D(0.0f, 0.0f);

		AHumanPlayer Pawn = (GM != nullptr) ? GM.HumanPawn : nullptr;
		if (Pawn != nullptr)
			Pawn.TouchMove(0.0f, 0.0f);
	}
}
