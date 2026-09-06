// Broadcast camera. Reorients between two rigs so the court's long (16 m)
// side always runs along the screen's long side, whichever way the device is
// held — see EndCamPos / SideCamPos below. Two standing rules (Erik,
// 2026-09-06): EVERY PLAYER IS ALWAYS VISIBLE, and the camera ALWAYS FOLLOWS
// THE BALL. Follow is TRANSLATION and TILT, never PAN: the rig slides in the
// court's X/Y (CamFollowAmount, toward the ball) and tilts up/down with the
// ball's height, but its YAW NEVER TURNS — an earlier attempt also panned
// yaw onto the ball and Erik corrected it ("kameran tittar höger/vänster"):
// this rig slides and tilts like a camera on a vertical post that can crane,
// it does not swivel its head. Visibility is the zoom (FitFieldOfView fits a
// box around the actual live positions of all four players and the ball,
// not a fixed-size zone or the court's static corners — see that function).
// The box is exactly as tight as the players currently make it: wide at
// serve-ready (server and receivers can be most of the court apart), tight
// once a rally clusters everyone near the net — no fixed number to retune
// when formations change.
class ABeachVolleyballCamera : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCameraComponent CameraComp;

	// PORTRAIT rig: behind Team A's baseline, looking down the court's length.
	// LANDSCAPE rig (below): off one sideline, looking across its width.
	// Full tuning history is in git log for these two lines; kept out of here
	// so this stays editable at a glance. Both survive the 2026-09-06
	// all-players-visible rework below unchanged: that rework only ever
	// SHRINKS the required FOV versus fitting the court's own corners (every
	// player is always somewhere inside those corners, never outside), and
	// these two positions already fit the full court comfortably under the
	// clamp — see FitFieldOfView's own comment for the reasoning and prior
	// measurements (2026-09-03 dolly, 2026-09-06 zoom rounds) if either
	// number ever needs to move again.
	FVector EndCamPos = FVector(-800, 0, 950);
	FVector SideCamPos = FVector(0, -1300, 1950);

	// Half-width (cm) of margin added around each player's and the ball's
	// position when FitFieldOfView builds its box — a raised arm or a dive
	// reaches past the character's own root, and the ball needs the same
	// so it doesn't sit flush on the frame edge exactly when it matters (a
	// spike at full extension). Trimmed 150 -> 100 (Erik, 2026-09-06:
	// "spelarna kan ha mindre marginal till skärmkanten") for a tighter crop
	// now that every player is guaranteed in frame regardless.
	const float SubjectMargin = 100.0f;

	FVector CamPos;
	bool bLandscape = false;

	// Smoothed actual position — CamPos above is the RIG'S ANCHOR (what a
	// portrait/landscape flip snaps back to); this is where the camera
	// actually sits once the ball-follow offset below is eased in. Kept
	// separate so a hard orientation cut can still reset instantly (see
	// UpdateOrientation) instead of the follow-lerp smearing across it.
	FVector CurrentCamPos;

	// How much of the ball's court-space X/Y the rig slides toward, on top
	// of its fixed anchor (Erik, 2026-09-06: "röra sig i planens x/y led" —
	// move in the court's X/Y — after ruling out panning for this; see the
	// class comment). UNTESTED value — pick a middle ground between the
	// earlier "0.2 moves too much" and "0.04 was imperceptible" verdicts
	// from when this same slide was layered on TOP OF a pan that was doing
	// most of the work; here it's the only horizontal follow there is, so it
	// likely wants to read as more present than 0.04 did. Tune by feel.
	float CamFollowAmount = 0.1f;

	// Aim point. Height only — X/Y stay at court centre (see the class
	// comment on why this rig doesn't pan). Z tracks the ball so tilt lifts
	// smoothly with it; falls back to 140 only in the gap before the ball
	// actor exists at all.
	FVector CurrentLookAt = FVector(0, 0, 140);

	float FollowSpeed = 4.0f;

	// All four players, found once and reused every frame by FitFieldOfView
	// (see FindPlayers).
	UPROPERTY()
	TArray<AVolleyballPlayer> Players;

	UPROPERTY()
	ABall Ball;

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		// FitFieldOfView's math assumes FieldOfView IS the horizontal fov and
		// stays fixed as aspect ratio changes (MaintainXFOV). Force it instead
		// of trusting the ambient default: BaseEngine.ini actually ships
		// AspectRatioAxisConstraint=MaintainYFOV project-wide, which is what
		// caused both real-device bugs this replaces (see FitFieldOfView) —
		// under that default, FieldOfView instead pins a fixed VERTICAL fov
		// (converted once via the component's own AspectRatio property, not
		// the live viewport) and lets horizontal float with the aspect ratio.
		CameraComp.bOverrideAspectRatioAxisConstraint = true;
		CameraComp.AspectRatioAxisConstraint = EAspectRatioAxisConstraint::AspectRatio_MaintainXFOV;

		UpdateOrientation();
		CurrentCamPos = CamPos;
		SetActorLocation(CurrentCamPos);

		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC != nullptr)
			PC.SetViewTargetWithBlend(this, 0.0f);

		FindBall();
		FindPlayers();
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (Ball == nullptr) FindBall();
		if (Players.Num() == 0) FindPlayers();

		UpdateOrientation();

		// TILT tracks the ball's height (X/Y stay at court centre — see
		// CurrentLookAt's own comment) so the rig cranes up and down with it.
		FVector Target = FVector(0, 0, 140);
		if (Ball != nullptr)
			Target.Z = Math::Clamp(140.0f + Ball.Position.Z * 0.25f, 140.0f, 320.0f);

		// Smooth tilt toward target
		float Alpha = Math::Clamp(FollowSpeed * DeltaTime, 0.0f, 1.0f);
		CurrentLookAt = CurrentLookAt + (Target - CurrentLookAt) * Alpha;

		// SLIDE (translate) toward the ball's X/Y, on top of the fixed
		// anchor — this is the "kameran ska alltid följa bollen" rule now
		// that panning is ruled out (see class comment). Same easing timer
		// as the tilt above.
		FVector PosTarget = CamPos;
		if (Ball != nullptr)
			PosTarget += FVector(Ball.Position.X, Ball.Position.Y, 0.0f) * CamFollowAmount;
		CurrentCamPos = CurrentCamPos + (PosTarget - CurrentCamPos) * Alpha;
		SetActorLocation(CurrentCamPos);

		// Yaw fixed at court centre, computed from the ANCHOR (CamPos), not
		// the live sliding position — so translating never turns the head
		// even slightly (Erik, 2026-09-06: "kameran tittar höger/vänster",
		// correcting an earlier attempt that panned yaw onto the ball; see
		// git log). Pitch answers to CurrentLookAt.Z alone, also using the
		// anchor's fixed horizontal reference distance, for the same reason
		// FitFieldOfView still reads the ACTUAL live position (GetActorLocation,
		// i.e. CurrentCamPos) every frame regardless — the slide changes what
		// fits in frame; it must not also fight the fixed aim direction.
		FVector ToTarget = CurrentLookAt - CamPos;
		float Yaw = FVector(ToTarget.X, ToTarget.Y, 0.0f).Rotation().Yaw;
		float RefHorizDist = FVector(CamPos.X, CamPos.Y, 0.0f).Size();
		float Pitch = Math::Atan2(ToTarget.Z, RefHorizDist) * (180.0f / PI);
		SetActorRotation(FRotator(Pitch, Yaw, 0.0f));

		FitFieldOfView(DeltaTime);
	}

	// Switches camera rig when the device/window flips between landscape and
	// portrait. A hard cut on rotation (no blend) matches how the OS itself
	// reflows the screen — there's no in-between orientation to blend through.
	private void UpdateOrientation()
	{
		FVector2D ViewportSize = WidgetLayout::GetViewportSize();
		bool bNowLandscape = ViewportSize.X > ViewportSize.Y;
		if (bNowLandscape == bLandscape && CamPos.SizeSquared() > 0.0f)
			return;

		bLandscape = bNowLandscape;
		CamPos = bLandscape ? SideCamPos : EndCamPos;
		CurrentCamPos = CamPos; // hard cut, not eased — see CurrentCamPos's own comment
		SetActorLocation(CurrentCamPos);
	}

	// 2026-09-02: replaces two hand-tuned CamPos distances (one scaled from
	// the other by court length/width, then eyeballed against a single
	// headless 1280x720 screenshot — see git history) after Erik reported
	// BOTH were wrong on his real device (Razr 50): landscape needed "at
	// least 3x zoom in" and portrait only showed the far baseline, not the
	// near one.
	//
	// Root cause: BaseEngine.ini ships project-wide
	// AspectRatioAxisConstraint=MaintainYFOV (checked — no project override).
	// Under that default, CameraComponent::FieldOfView does NOT mean "this is
	// the horizontal fov, always" despite what its own doc comment implies in
	// isolation — MaintainYFOV converts it ONCE into a fixed vertical fov
	// (using the component's own AspectRatio property, a fixed ~16:9-ish
	// default, NOT the live viewport) and holds THAT constant, letting
	// horizontal float with the real aspect ratio instead. So: portrait's
	// tall/narrow real screen still only got that same modest fixed vertical
	// slice — not enough to also reach the steep look-down angle to the near
	// baseline (250cm behind it, camera height 850 — a ~74 deg look-down vs.
	// the ~29 deg half-fov MaintainYFOV was actually giving it), so the near
	// baseline fell below the bottom of frame while the shallower-angled far
	// baseline stayed in. Landscape's wide real screen (a Razr 50 unfolds to
	// a very wide aspect) inflated the FLOATING horizontal fov far past what
	// the 16m length needed, so the court read tiny in the middle of a much
	// wider frame than intended — "zoom in 3x" is roughly what shrinking that
	// oversized horizontal fov back down looks like.
	//
	// No fixed CamPos distance/FOV pair is correct for every device this way —
	// the same numbers produce a different crop on every aspect ratio
	// depending on which axis MaintainYFOV happens to hold fixed. Fix: force
	// MaintainXFOV instead (BeginPlay — makes FieldOfView deterministically
	// the horizontal fov, full stop), then compute that horizontal fov HERE,
	// every frame, from the actual runtime aspect ratio and the actual
	// current camera transform.
	//
	// FITS A BOX AROUND EVERY PLAYER AND THE BALL, NOT THE COURT (reworked
	// 2026-09-06 for Erik's "alla spelare ska alltid synas" — every player
	// always visible). One earlier revision fit a fixed-size zone around just
	// the ball instead; that produced a real zoomed-in look but let players
	// standing away from the ball fall out of frame, which is exactly the
	// rule this replaces it to satisfy. Corners are each subject's actual
	// live position ± SubjectMargin in X/Y, with world Z in {0, ActionHeight}
	// (ground contact and jump apex — a subject can go from grounded to
	// airborne at any spot on the court, independent of X/Y). This can never
	// need MORE field of view than fitting the court's own static corners
	// did (no player can stand outside the court), so EndCamPos/SideCamPos
	// need no retuning for this change — see their own comment.
	private void FitFieldOfView(float DeltaTime)
	{
		FVector Forward = GetActorForwardVector();
		FVector Right = GetActorRightVector();
		FVector Up = GetActorUpVector();
		FVector Eye = GetActorLocation();

		const float ActionHeight = 320.0f; // headroom for a jumping spiker / high ball

		TArray<FVector> Subjects;
		for (int i = 0; i < Players.Num(); i++)
		{
			if (Players[i] != nullptr)
				Subjects.Add(Players[i].GetActorLocation());
		}
		if (Ball != nullptr)
			Subjects.Add(Ball.Position);
		if (Subjects.Num() == 0)
			Subjects.Add(FVector(0, 0, 140)); // nothing spawned yet — hold on court centre

		float MaxHoriz = 0.0f;
		float MaxVert = 0.0f;
		int WorstSubject = -1;
		for (int s = 0; s < Subjects.Num(); s++)
		{
			for (int ix = 0; ix < 2; ix++)
			{
				float X = Subjects[s].X + ((ix == 0) ? -SubjectMargin : SubjectMargin);
				for (int iy = 0; iy < 2; iy++)
				{
					float Y = Subjects[s].Y + ((iy == 0) ? -SubjectMargin : SubjectMargin);
					for (int iz = 0; iz < 2; iz++)
					{
						float Z = (iz == 0) ? 0.0f : ActionHeight;

						FVector ToPoint = FVector(X, Y, Z) - Eye;
						float Depth = ToPoint.DotProduct(Forward);
						if (Depth < 50.0f)
							continue; // behind the camera — shouldn't happen, ignore defensively

						float Horiz = Math::Abs(Math::Atan2(ToPoint.DotProduct(Right), Depth));
						float Vert = Math::Abs(Math::Atan2(ToPoint.DotProduct(Up), Depth));
						if (Horiz > MaxHoriz) { MaxHoriz = Horiz; WorstSubject = s; }
						if (Vert > MaxVert) { MaxVert = Vert; WorstSubject = s; }
					}
				}
			}
		}

		// Fixed angular margin (not a multiplier) so the court never sits flush
		// against the frame edge, on any aspect ratio.
		float MarginRad = 4.0f * (PI / 180.0f);
		MaxHoriz += MarginRad;
		MaxVert += MarginRad;

		FVector2D ViewportSize = WidgetLayout::GetViewportSize();
		float Aspect = (ViewportSize.Y > 1.0f) ? (ViewportSize.X / ViewportSize.Y) : 1.7778f;

		// FieldOfView is horizontal (forced MaintainXFOV in BeginPlay). Directly
		// satisfies the horizontal requirement; for the vertical requirement,
		// invert MaintainXFOV's own conversion (tan(v/2) = tan(h/2) / aspect)
		// to find the horizontal fov that produces AT LEAST that vertical fov.
		float FovFromHoriz = 2.0f * MaxHoriz;
		float FovFromVert = 2.0f * Math::Atan2(Aspect * Math::Tan(MaxVert), 1.0f);
		float FovH = Math::Max(FovFromHoriz, FovFromVert) * (180.0f / PI);

		// Safety net, not a chosen look: 105 was picked (2026-09-06, "för
		// mycket fisheye") when a too-close CamPos pegged 130 with a corner
		// still clipped. The all-players box above can only ask for LESS FOV
		// than the full-court fit these positions were already sized for, so
		// this should not bind in normal play — see ClipLogCooldown below for
		// an automated signal if it ever does.
		float ClampedFovH = Math::Clamp(FovH, 30.0f, 105.0f);
		CameraComp.FieldOfView = ClampedFovH;

		// AUTO-TEST FOR "alla spelare ska alltid synas": if the clamp above
		// actually had to cut FovH down, something (a player or the ball) is
		// outside frame RIGHT NOW, full stop — this isn't a heuristic, it's
		// the same angle math the frame itself is drawn from. Rate-limited to
		// avoid spamming every frame of a genuine violation; grep a headless
		// run's log for CAMCLIP to check this rule automatically instead of
		// eyeballing screenshots.
		ClipLogCooldown -= DeltaTime;
		if (ClampedFovH < FovH - 0.5f && ClipLogCooldown <= 0.0f)
		{
			// viewport/aspect included on purpose: a nullrhi/headless run with
			// no real swapchain reports ViewportSize (0,0), which falls back
			// to the 16:9 default above regardless of which rig is active —
			// that alone produced a wall of false CAMCLIP hits (required up
			// to 153°) the day this was added. A real aspect near 0 here
			// means "ignore this run", not "the rule is broken".
			FVector WP = (WorstSubject >= 0) ? Subjects[WorstSubject] : FVector::ZeroVector;
			Log("CAMCLIP required=" + int(FovH) + " clamped=" + int(ClampedFovH)
				+ " subjects=" + Subjects.Num() + " worst=" + WorstSubject
				+ " worstPos=(" + int(WP.X) + "," + int(WP.Y) + "," + int(WP.Z) + ")"
				+ " eye=(" + int(Eye.X) + "," + int(Eye.Y) + "," + int(Eye.Z) + ")"
				+ " viewport=(" + ViewportSize.X + "," + ViewportSize.Y + ") aspect=" + Aspect);
			ClipLogCooldown = 1.0f;
		}
	}
	private float ClipLogCooldown = 0.0f;

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}

	private void FindPlayers()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(AVolleyballPlayer, Found);
		Players.Empty();
		for (int i = 0; i < Found.Num(); i++)
		{
			AVolleyballPlayer P = Cast<AVolleyballPlayer>(Found[i]);
			if (P != nullptr)
				Players.Add(P);
		}
	}
}
