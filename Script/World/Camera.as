// Broadcast camera. Reorients between two rigs so the court's long (16 m)
// side always runs along the screen's long side, whichever way the device is
// held — see EndCamPos / SideCamPos below. Field of view is fit dynamically
// every frame (FitFieldOfView) around a small zone centred on the ball
// (FocusHalfExtent) rather than the whole court — see that function and
// 2026-09-06's comment on EndCamPos for why "the whole court always in
// frame" and "zoomed in" cannot both be true from a fixed rig, and why this
// class no longer tries for the former.
class ABeachVolleyballCamera : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCameraComponent CameraComp;

	// PORTRAIT rig: behind Team A's baseline, looking down the court's length.
	// LANDSCAPE rig (below): off one sideline, looking across its width.
	// Full tuning history is in git log for these two lines; kept out of here
	// so this stays editable at a glance — the short version, current as of
	// 2026-09-06:
	//
	// Earlier revisions of this file tried to keep the WHOLE 16x8m court in
	// frame at all times, which caps how much "zoom" is possible from a fixed
	// rig: FitFieldOfView had to widen (fisheye-prone) for any court corner
	// that got too close. Erik asked to "dubbla zoomen" (double the zoom) —
	// not reachable under that rule (halving these distances measured
	// 137-170° required FOV, plus a latent bug where FitFieldOfView's own
	// depth<50 skip starts dropping corners from the calculation entirely at
	// that range, silently under-fitting). Decided instead to DROP the
	// whole-court guarantee: FitFieldOfView (below) now fits a small zone
	// centred on the ball (FocusHalfExtent) rather than the court's corners,
	// so the far side of the court routinely leaves frame during play — the
	// tradeoff Erik chose for a real telephoto-zoomed shot of the action.
	//
	// THE ACTUAL ZOOM LEVER IS FocusHalfExtent, NOT THIS DISTANCE — caught by
	// rendering before this shipped: the first attempt just moved both rigs
	// much farther back with the same 350 half-extent, on the reasoning that
	// farther = narrower FOV = more telephoto. True, but useless on its own —
	// narrowing FOV to match a farther camera at the SAME box size reproduces
	// the SAME on-screen framing (that's what "zoom compensation" means), not
	// a bigger one. A screenshot at that distance showed the entire court
	// still comfortably in frame — no tighter than before FocusHalfExtent
	// existed. Real magnification needs the box itself smaller at a given
	// distance; distance here is now just each rig's own knob for matching
	// its FOV to the other rig's, not the zoom control.
	FVector EndCamPos = FVector(-800, 0, 950);   // unchanged from the previous round
	FVector SideCamPos = FVector(0, -1300, 1950); // moved out along the same angle
	// (33.7° off vertical, same as before) so landscape's naturally-tighter
	// geometry at short range doesn't need a different FocusHalfExtent than
	// portrait's to land on a comparable FOV.

	// Half-size (cm) of the square zone around the ball that FitFieldOfView
	// guarantees stays in frame — NOT the court's own half-extents anymore
	// (see EndCamPos's comment). 200 = a 4x4m window: a hitter and the
	// teammate setting them up, not the far baseline. Halved from an
	// unrendered first guess (350) once the math above was actually checked
	// against a screenshot. With the CamPos values above this measures
	// ~34-45° across the whole court (ball at centre vs. right at this rig's
	// baseline) for both rigs — roughly half the ~89-91° either rig measured
	// under the old whole-court fit, i.e. Erik's "dubbla zoomen" taken at
	// face value.
	const float FocusHalfExtent = 200.0f;

	FVector CamPos;
	bool bLandscape = false;

	// Aim point. Defaults to court centre; Tick pans/tilts it onto the ball's
	// full X/Y/Z once one is live (see Tick) — this is now the ONLY thing
	// that tracks play, and it does double duty: FitFieldOfView's focus zone
	// (FocusHalfExtent) is centred on this same point, so panning onto the
	// ball is also what keeps it inside the now much-tighter frame. An
	// earlier revision (2026-09-05) additionally nudged CamPos itself toward
	// the ball ("den borde även följa bollen en del") on top of this; removed
	// once this pan/tilt started carrying the ball's X/Y too — physically
	// moving the rig on top of a camera that already aims itself at the ball
	// every frame was redundant, not a second effect stacking usefully.
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

		// Look at court centre by default; once the ball is live, pan/tilt the
		// aim onto it (X/Y directly, Z gently clamped so a high ball doesn't
		// tilt the camera up into empty sky). This is now the PRIMARY way the
		// camera tracks play — FitFieldOfView's focus zone (FocusHalfExtent)
		// is centred on this same point, so panning onto the ball is what
		// keeps it (and not empty sand) inside the zoomed-in frame.
		FVector Target = FVector(0, 0, 140);
		if (Ball != nullptr && Ball.bInPlay)
		{
			Target.X = Ball.Position.X;
			Target.Y = Ball.Position.Y;
			Target.Z = Math::Clamp(140.0f + Ball.Position.Z * 0.25f, 140.0f, 320.0f);
		}

		// Smooth pan/tilt toward target
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
	// No fixed CamPos distance/FOV pair is correct for every device this way —
	// the same numbers produce a different crop on every aspect ratio
	// depending on which axis MaintainYFOV happens to hold fixed. Fix: force
	// MaintainXFOV instead (BeginPlay — makes FieldOfView deterministically
	// the horizontal fov, full stop), then compute that horizontal fov HERE,
	// every frame, from the actual runtime aspect ratio and the actual
	// current camera transform.
	//
	// FITS A ZONE AROUND THE BALL, NOT THE COURT (changed 2026-09-06 — see
	// EndCamPos's comment for why). The eight corners below are
	// (CurrentLookAt.X/Y ± FocusHalfExtent, world Z in {0, ActionHeight}):
	// X/Y move with wherever the camera is currently panned/tilted (the ball,
	// once one is live), Z stays two absolute world heights — ground contact
	// and jump apex — regardless of where that pan point is, since a player
	// can go from grounded to airborne at any spot on the court.
	private void FitFieldOfView()
	{
		FVector Forward = GetActorForwardVector();
		FVector Right = GetActorRightVector();
		FVector Up = GetActorUpVector();
		FVector Eye = GetActorLocation();

		const float ActionHeight = 320.0f; // headroom for a jumping spiker / high ball
		float FocusX = CurrentLookAt.X;
		float FocusY = CurrentLookAt.Y;

		float MaxHoriz = 0.0f;
		float MaxVert = 0.0f;
		for (int ix = 0; ix < 2; ix++)
		{
			float X = FocusX + ((ix == 0) ? -FocusHalfExtent : FocusHalfExtent);
			for (int iy = 0; iy < 2; iy++)
			{
				float Y = FocusY + ((iy == 0) ? -FocusHalfExtent : FocusHalfExtent);
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

		// Upper bound dropped 130 -> 105 (Erik, 2026-09-06: "för mycket fisheye"),
		// kept as a safety net after the focus-zone rework above: current
		// EndCamPos/SideCamPos/FocusHalfExtent measure ~34-45° across the
		// whole court (ball at centre vs. ball right at this rig's own
		// baseline, the worst case), nowhere near 105 — so hitting this clamp
		// now means either FocusHalfExtent grew a lot or a CamPos got moved
		// much closer again, not routine play.
		CameraComp.FieldOfView = Math::Clamp(FovH, 30.0f, 105.0f);
	}

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
