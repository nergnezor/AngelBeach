// Fixed broadcast camera. Reorients between two rigs so the court's long
// (16 m) side always runs along the screen's long side, whichever way the
// device is held — see EndCamPos / SideCamPos below. Field of view is fit
// dynamically every frame (FitFieldOfView) rather than relying on a hand-tuned
// distance per rig, so the whole court stays in frame on any real device
// aspect ratio — see that function for why a fixed distance can't do this.
class ABeachVolleyballCamera : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCameraComponent CameraComp;

	// PORTRAIT rig: behind Team A's baseline, looking down the length of the court,
	// so the 16 m length reads as vertical depth (near/far baseline separation) —
	// the tall screen axis. This is the original (and only, pre-2026-09-02) camera.
	//
	// HEIGHT IS THE DEPTH CUE. At the old 420 the view was almost level with the
	// sand, which foreshortens the court so hard that 16 m of depth collapsed into a
	// thin band — the whole playfield occupied barely a third of the frame height and
	// there was no way to judge how far apart anyone stood. Lifting the eye opens the
	// court back out into a readable rectangle: near and far baselines separate, the
	// gap between players becomes a distance you can actually see.
	//
	// RAISED AGAIN 2026-09-01, 560 -> 850, distance still unchanged at 1050.
	// Erik asked for players/lines/ball position to read as clearly as possible —
	// a broadcast-style steeper angle over the old cinematic one that was tuned to
	// keep the sunset horizon in frame. Deliberately not the earlier-rejected
	// 900 @ -1250: that combo moved the camera BACK at the same time it went up,
	// which is what shrank the court to a small rectangle with an empty foreground —
	// the failure was the added distance, not the height. Raising the eye alone
	// (distance held at the original 1050) buys the steeper, more plan-like angle
	// on the court lines and ball height without that penalty.
	//
	// The distance/height here only sets the CAMERA'S POSITION now — how tight the
	// shot reads is FitFieldOfView's job, not this number (see 2026-09-02 note there).
	//
	// DOLLIED BACK 2026-09-03, 1050/850 -> 2100/1560 (Erik: portrait's sidelines
	// converged too hard toward a vanishing point — wanted them flatter/more
	// parallel, plus tighter margins). The note above ("the failure was the
	// added distance, not the height") is from BEFORE FitFieldOfView existed:
	// under a fixed/hand-tuned FOV, moving back really did just shrink the
	// court into a small rectangle with empty foreground. Now FOV is
	// recomputed every frame from the LIVE camera position (FitFieldOfView),
	// so moving back is compensated by an automatically narrower FOV —
	// framing tightness is preserved, only perspective convergence drops.
	// This is a straight 2x dolly-back along the same look-at ray (same
	// downward viewing angle, so the tuned legibility/steepness is
	// unchanged) — MEASURED (computed, not yet seen — this machine cannot
	// render, see nullrhi-different-simulation): raw content half-angles
	// roughly halve (42°/44° -> 17°/20°), and the excess margin that
	// FitFieldOfView's max(horiz,vert) leaves on the non-binding axis at a
	// tall phone aspect drops from ~20° to ~13°. Fully eliminating that
	// excess needs a near-overhead angle, which trades away the steep
	// broadcast look tuned above — this is the flattening trade Erik chose
	// over that.
	//
	// DOLLIED BACK AGAIN 2026-09-05 (Erik: "mer inzoomad kamera och lite
	// mindre perspektiv" — more zoomed-in, a bit less perspective). Same
	// lever as above: another ~1.3x dolly-back along the ray toward
	// CurrentLookAt (0,0,140), not a raw scale of these numbers — the pivot
	// is the look-at point, not the origin (that's why the 2026-09-03 step
	// was 1050->2100 on X but 850->1560, not 1700, on Z: 2x of the
	// LookAt-relative offset (-1050,710), not of the raw position). Farther
	// + auto-narrowed FOV reads as more telephoto: same framing, flatter
	// convergence — "more zoomed in" and "less perspective" are the same
	// knob here, not two separate asks. UNVERIFIED on this machine (no
	// render), same as the step above — Erik to confirm on device and call
	// for more/less.
	FVector EndCamPos = FVector(-2730, 0, 1986);

	// LANDSCAPE rig: off one sideline, centred on the net, looking across the
	// court's width, so the 16 m length spans the screen's wide axis directly
	// instead of receding into depth. Centred on X=0 (not Team-A's baseline)
	// since a side-on broadcast shot has no "near" team the way an end-zone
	// shot does.
	// Dollied back 2026-09-05 alongside EndCamPos above — same ~1.3x
	// LookAt-relative dolly, same reasoning.
	FVector SideCamPos = FVector(0, -2210, 1713);

	FVector CamPos;
	bool bLandscape = false;

	// Aim point unchanged. Raising CamPos alone already steepens the downward angle;
	// the horizon/sunset backdrop this used to preserve is a secondary concern now
	// that legibility of players/lines/ball is the stated goal.
	FVector CurrentLookAt = FVector(0, 0, 140);

	float FollowSpeed = 4.0f;

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
		SetActorLocation(CamPos);

		APlayerController PC = Gameplay::GetPlayerController(0);
		if (PC != nullptr)
			PC.SetViewTargetWithBlend(this, 0.0f);

		FindBall();
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		if (Ball == nullptr) FindBall();

		UpdateOrientation();

		// Look at court centre; follow the ball's height only gently and clamp it so
		// the camera never tilts up into empty sky on high balls.
		FVector Target = FVector(0, 0, 140);
		if (Ball != nullptr && Ball.bInPlay)
			Target.Z = Math::Clamp(140.0f + Ball.Position.Z * 0.25f, 140.0f, 320.0f);

		// Smooth tilt toward target
		float Alpha = Math::Clamp(FollowSpeed * DeltaTime, 0.0f, 1.0f);
		CurrentLookAt = CurrentLookAt + (Target - CurrentLookAt) * Alpha;

		FVector LookDir = (CurrentLookAt - CamPos).GetSafeNormal();
		SetActorRotation(LookDir.Rotation());

		FitFieldOfView();
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
		SetActorLocation(CamPos);
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
	// No fixed CamPos distance is correct for every device this way — the
	// same numbers produce a different crop on every aspect ratio depending
	// on which axis MaintainYFOV happens to hold fixed. Fix: force
	// MaintainXFOV instead (BeginPlay — makes FieldOfView deterministically
	// the horizontal fov, full stop), then compute that horizontal fov HERE,
	// every frame, from the actual runtime aspect ratio and the actual
	// current camera transform, large enough that the court's full ground
	// rectangle (both baselines, both sidelines) PLUS some headroom for a
	// jumping spiker/high ball is guaranteed inside frame — instead of
	// hoping a hand-picked distance happens to produce that on whatever
	// screen it's shown on.
	private void FitFieldOfView()
	{
		FVector Forward = GetActorForwardVector();
		FVector Right = GetActorRightVector();
		FVector Up = GetActorUpVector();
		FVector Eye = GetActorLocation();

		const float HalfLength = 800.0f;  // Court.as CourtHalfLength (16m/2)
		const float HalfWidth = 400.0f;   // Court.as CourtHalfWidth (8m/2)
		const float ActionHeight = 320.0f; // headroom for a jumping spiker / high ball

		float MaxHoriz = 0.0f;
		float MaxVert = 0.0f;
		for (int ix = 0; ix < 2; ix++)
		{
			float X = (ix == 0) ? -HalfLength : HalfLength;
			for (int iy = 0; iy < 2; iy++)
			{
				float Y = (iy == 0) ? -HalfWidth : HalfWidth;
				for (int iz = 0; iz < 2; iz++)
				{
					float Z = (iz == 0) ? 0.0f : ActionHeight;

					FVector ToPoint = FVector(X, Y, Z) - Eye;
					float Depth = ToPoint.DotProduct(Forward);
					if (Depth < 50.0f)
						continue; // behind the camera — shouldn't happen, ignore defensively

					float Horiz = Math::Abs(Math::Atan2(ToPoint.DotProduct(Right), Depth));
					float Vert = Math::Abs(Math::Atan2(ToPoint.DotProduct(Up), Depth));
					MaxHoriz = Math::Max(MaxHoriz, Horiz);
					MaxVert = Math::Max(MaxVert, Vert);
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

		CameraComp.FieldOfView = Math::Clamp(FovH, 30.0f, 130.0f);
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
