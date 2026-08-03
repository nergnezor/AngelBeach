// HUD placeholder - score display is handled via UMG or future widget implementation.
//
// The one thing actually drawn here is the Android on-screen control scheme: a
// drag joystick (movement) and four tap buttons (Jump/Pass/Set/Spike), the touch
// equivalent of the WASD + Space/E/LeftShift/F bindings in DefaultInput.ini.
// Desktop/gamepad players never see this — AHumanPlayer already plays itself as
// AI until real input arrives, and IsMobilePlatform() keeps it off everywhere
// that isn't Android/iOS. Drawn with AHUD::DrawRect/DrawText (no textures) to
// match the "no binary assets in git" rule in CLAUDE.md.

class ABeachVolleyballHUD : AHUD
{
	private ABeachVolleyballGameMode GM;
	private bool bTouchControlsActive = false;

	// Updated every DrawHUD; touch handlers reuse the last known size rather
	// than querying the viewport again.
	private float ScreenSizeX = 1280.0f;
	private float ScreenSizeY = 720.0f;

	// -1 = no finger currently driving the joystick.
	private int32 MoveFingerIndex = -1;
	private FVector2D MoveOrigin = FVector2D(0.0f, 0.0f);
	private FVector2D JoystickKnobOffset = FVector2D(0.0f, 0.0f);

	private const float JoystickRadius = 100.0f;
	private const float JoystickDeadZone = 10.0f;
	private const float ButtonRadius = 48.0f;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		GM = Cast<ABeachVolleyballGameMode>(GetWorld().GetAuthGameMode());
		bTouchControlsActive = GM != nullptr && GM.IsMobilePlatform();
		if (!bTouchControlsActive)
			return;

		APlayerController PC = GetOwningPlayerController();
		if (PC != nullptr)
		{
			PC.OnInputTouchBegin.AddUFunction(this, n"OnTouchBegin");
			PC.OnInputTouchMoved.AddUFunction(this, n"OnTouchMoved");
			PC.OnInputTouchEnd.AddUFunction(this, n"OnTouchEnd");
		}
	}

	UFUNCTION(BlueprintOverride)
	void ReceiveDrawHUD(int SizeX, int SizeY)
	{
		if (!bTouchControlsActive)
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
		FVector2D Base = (MoveFingerIndex >= 0) ? MoveOrigin : JoystickIdleBase();

		DrawRect(FLinearColor(0.0f, 0.0f, 0.0f, 0.25f),
			Base.X - JoystickRadius, Base.Y - JoystickRadius,
			JoystickRadius * 2.0f, JoystickRadius * 2.0f);

		FVector2D Knob = Base + JoystickKnobOffset;
		float KnobRadius = 34.0f;
		FLinearColor KnobColor = (MoveFingerIndex >= 0)
			? FLinearColor(1.0f, 1.0f, 1.0f, 0.55f)
			: FLinearColor(1.0f, 1.0f, 1.0f, 0.30f);
		DrawRect(KnobColor, Knob.X - KnobRadius, Knob.Y - KnobRadius, KnobRadius * 2.0f, KnobRadius * 2.0f);
	}

	private void DrawButton(FVector2D Center, FString Label)
	{
		DrawRect(FLinearColor(0.0f, 0.0f, 0.0f, 0.30f),
			Center.X - ButtonRadius, Center.Y - ButtonRadius,
			ButtonRadius * 2.0f, ButtonRadius * 2.0f);

		float TextW = 0.0f;
		float TextH = 0.0f;
		GetTextSize(Label, TextW, TextH, nullptr, 1.0f);
		DrawText(Label, FLinearColor(1.0f, 1.0f, 1.0f, 0.85f),
			Center.X - TextW * 0.5f, Center.Y - TextH * 0.5f, nullptr, 1.0f, false);
	}

	// ---- Touch handling --------------------------------------------------

	UFUNCTION()
	void OnTouchBegin(ETouchIndex::Type FingerIndex, FVector Location)
	{
		AHumanPlayer Pawn = (GM != nullptr) ? GM.HumanPawn : nullptr;
		if (Pawn == nullptr)
			return;

		// Left half of the screen: claim this finger for the movement joystick
		// (first finger there wins; a second finger already inside doesn't
		// steal it, so a button tap by the same hand can't derail movement).
		if (Location.X < ScreenSizeX * 0.5f)
		{
			if (MoveFingerIndex == -1)
			{
				MoveFingerIndex = int(FingerIndex);
				MoveOrigin = FVector2D(Location.X, Location.Y);
				JoystickKnobOffset = FVector2D(0.0f, 0.0f);
				Pawn.TouchMove(0.0f, 0.0f);
			}
			return;
		}

		// Right half: hit-test the four action buttons.
		FVector2D Touch = FVector2D(Location.X, Location.Y);
		if ((Touch - JumpCenter()).Size() <= ButtonRadius)
			Pawn.TouchJump();
		else if ((Touch - PassCenter()).Size() <= ButtonRadius)
			Pawn.TouchPass();
		else if ((Touch - SetCenter()).Size() <= ButtonRadius)
			Pawn.TouchSet();
		else if ((Touch - SpikeCenter()).Size() <= ButtonRadius)
			Pawn.TouchSpike();
	}

	UFUNCTION()
	void OnTouchMoved(ETouchIndex::Type FingerIndex, FVector Location)
	{
		if (int(FingerIndex) != MoveFingerIndex)
			return;

		AHumanPlayer Pawn = (GM != nullptr) ? GM.HumanPawn : nullptr;
		if (Pawn == nullptr)
			return;

		FVector2D Delta = FVector2D(Location.X, Location.Y) - MoveOrigin;
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
		Pawn.TouchMove(Forward, Right);
	}

	UFUNCTION()
	void OnTouchEnd(ETouchIndex::Type FingerIndex, FVector Location)
	{
		if (int(FingerIndex) != MoveFingerIndex)
			return;

		MoveFingerIndex = -1;
		JoystickKnobOffset = FVector2D(0.0f, 0.0f);

		AHumanPlayer Pawn = (GM != nullptr) ? GM.HumanPawn : nullptr;
		if (Pawn != nullptr)
			Pawn.TouchMove(0.0f, 0.0f);
	}
}
