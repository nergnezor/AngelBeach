// Human player - inherits the full AI state machine and plays as a coordinated
// AI teammate until gamepad input is detected, then becomes player-controlled.

class AHumanPlayer : AAIPlayer
{
	UPROPERTY(DefaultComponent)
	UInputComponent ScriptInputComponent;

	// True while a human is actually driving this pawn. NOT a latch: see
	// ControlReleaseDelay below.
	bool bPlayerControlled = false;

	// TAKING CONTROL IS A MOVEMENT DECISION, AND IT IS REVOCABLE.
	//
	// Both halves of that sentence are repairs for a measured bug: this pawn ran
	// the whole match without ever reaching its AI brain. TakeControl() used to
	// be a permanent latch that ANY bound input could set, including the four
	// action buttons -- and something fired the Set action two seconds into a
	// headless match with no input device attached (TAKECONTROL src=DoSet).
	// From that frame on, Tick took the player-controlled branch, fed
	// MovePlayer() an all-zero axis pair and returned before RunAIBrain: the
	// player stood still for the rest of the match. Measured over a full match,
	// A/Back reached its decision loop 30 times against B/Back's 888, and moved
	// 85cs per rally against the other three players' 365-404.
	//
	// So: only real movement asks for control (an action button press is not
	// evidence that anyone is steering), and control lapses back to the AI after
	// a stretch of complete silence. A human who is actually playing re-arms it
	// on their next stick nudge or button press, so the only thing the lapse can
	// take away is a takeover nobody asked for.
	const float ControlReleaseDelay = 4.0f;
	// Stick drift and a hair-trigger 0.1 both count as "someone is steering" at
	// the old threshold. A real push clears this easily.
	const float TakeControlDeadzone = 0.25f;
	private float InputIdleTime = 0.0f;

	// Input axes (used when bPlayerControlled == true)
	float AxisForward = 0.0f;
	float AxisRight = 0.0f;


	// Deliberately replaces AAIPlayer's BeginPlay/Tick (we gate the AI on
	// bPlayerControlled), so we intentionally do not call Super.
	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		TeamSide = ETeam::Team_A;
		Role = EPlayerRole::Role_Back;
		Difficulty = 0.75f;

		CourtMinX = -900.0f;
		CourtMaxX = -5.0f;
		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;

		MoveSpeed = 420.0f + Difficulty * 220.0f;
		ReactionDelay = Math::Lerp(0.35f, 0.04f, Difficulty);

		// Bind input — only fires when this pawn is possessed
		ScriptInputComponent.BindAxis(n"MoveForward",   FInputAxisHandlerDynamicSignature(this, n"OnMoveForward"));
		ScriptInputComponent.BindAxis(n"MoveRight",     FInputAxisHandlerDynamicSignature(this, n"OnMoveRight"));
		ScriptInputComponent.BindAction(n"Jump",  EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnJump"));
		ScriptInputComponent.BindAction(n"Pass",  EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnPass"));
		ScriptInputComponent.BindAction(n"Set",   EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnSet"));
		ScriptInputComponent.BindAction(n"Spike", EInputEvent::IE_Pressed, FInputActionHandlerDynamicSignature(this, n"OnSpike"));
		ScriptInputComponent.BindAction(n"LightGraphics", EInputEvent::IE_Pressed,
			FInputActionHandlerDynamicSignature(this, n"OnLightGraphics"));

		// No touch bindings here on purpose. Script in this fork cannot read the
		// raw touch stream at all: APlayerController.OnInputTouchBegin/End are
		// AActor's "this actor was touched" delegates (need collision, never fire
		// for a controller), APlayerController.GetInputTouchState isn't callable
		// with any argument spelling, and UInputComponent::BindTouch isn't bound.
		// So movement comes from the engine's virtual joystick via the ordinary
		// Gamepad_LeftX/Y axis mappings above (see Config/DefaultInput.ini), and
		// the action buttons come from HUD hit boxes (see ABeachVolleyballHUD).
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);

		if (Ball == nullptr) FindBall();

		// Split step reacts to opponent contacts at full frame rate (same as the
		// pure AI player — see AAIPlayer.Tick).
		UpdateSplitStep(DeltaTime);

		// Serve sequence owns the pawn (AI serves even for the human side until
		// gamepad serving exists). Runs through the follow-through past launch.
		if (bServing)
		{
			RunServeSequence(DeltaTime);
			return;
		}

		// Hand the pawn back to the AI once the human has gone quiet. Axis
		// handlers fire every frame with the current value, so silence really
		// does mean nobody is touching anything.
		if (bPlayerControlled)
		{
			InputIdleTime += DeltaTime;
			if (InputIdleTime >= ControlReleaseDelay)
			{
				bPlayerControlled = false;
				AxisForward = 0.0f;
				AxisRight = 0.0f;
			}
		}

		if (bPlayerControlled && Ball != nullptr && Ball.bInPlay)
		{
			// Direct control: player drives movement, hits via buttons
			MovePlayer(FVector2D(AxisForward, AxisRight));
			return;
		}

		// AI fallback — the SAME brain as AAIPlayer, not a copy of it: dead-ball
		// resets, perception latency and the reaction gate all included.
		RunAIBrain(DeltaTime);
	}

	// ---- Input handlers ----

	UFUNCTION()
	void OnMoveForward(float32 Value)
	{
		if (Math::Abs(Value) > TakeControlDeadzone)
		{
			InputIdleTime = 0.0f;
			if (!bPlayerControlled) TakeControl();
		}
		AxisForward = Value;
	}

	UFUNCTION()
	void OnMoveRight(float32 Value)
	{
		if (Math::Abs(Value) > TakeControlDeadzone)
		{
			InputIdleTime = 0.0f;
			if (!bPlayerControlled) TakeControl();
		}
		AxisRight = Value;
	}

	UFUNCTION()
	void OnJump(FKey Key)
	{
		DoJump();
	}

	UFUNCTION()
	void OnPass(FKey Key)
	{
		DoPass();
	}

	UFUNCTION()
	void OnSet(FKey Key)
	{
		DoSet();
	}

	UFUNCTION()
	void OnSpike(FKey Key)
	{
		DoSpike();
	}

	// B: the light graphics switch. Handled here because a possessed pawn is the
	// only place script gets keyboard input in this fork (the HUD sees touches,
	// not keys) — but it is a display setting, not a hit, so it goes straight to
	// the game mode and never touches InputIdleTime: pressing it is no more a
	// claim to steer this pawn than the action buttons are (see TakeControl).
	// No gamepad twin on purpose: the pad's B face button is already Spike.
	UFUNCTION()
	void OnLightGraphics(FKey Key)
	{
		if (GM != nullptr) GM.ToggleLightGraphics();
	}

	// ---- Touch input (Android on-screen controls; see ABeachVolleyballHUD) ----
	// The HUD drives these directly instead of the FKey-based handlers above:
	// there is no real key behind a screen tap, and the axis handlers already
	// take a plain float so they need no touch-specific twin.

	void TouchMove(float32 Forward, float32 Right)
	{
		OnMoveForward(Forward);
		OnMoveRight(Right);
	}

	void TouchJump()  { DoJump(); }
	void TouchPass()  { DoPass(); }
	void TouchSet()   { DoSet(); }
	void TouchSpike() { DoSpike(); }

	private void DoJump()
	{
		InputIdleTime = 0.0f;   // a press is activity, but not a steering claim
		Jump();
	}

	private void DoPass()
	{
		InputIdleTime = 0.0f;   // a press is activity, but not a steering claim
		if (Ball == nullptr) FindBall();
		TryPass(Ball);
	}

	private void DoSet()
	{
		InputIdleTime = 0.0f;   // a press is activity, but not a steering claim
		if (Ball == nullptr) FindBall();
		TrySet(Ball);
	}

	private void DoSpike()
	{
		InputIdleTime = 0.0f;   // a press is activity, but not a steering claim
		if (Ball == nullptr) FindBall();
		TrySpike(Ball);
	}

	private void TakeControl()
	{
		bPlayerControlled = true;
		Print("Player control activated!");
	}
}
