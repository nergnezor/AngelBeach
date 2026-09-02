// Fixed broadcast camera. Reorients between two rigs so the court's long
// (16 m) side always runs along the screen's long side, whichever way the
// device is held — see EndCamPos / SideCamPos below.
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
	FVector EndCamPos = FVector(-1050, 0, 850);

	// LANDSCAPE rig: off one sideline, centred on the net, looking across the
	// court's width, so the 16 m length spans the screen's wide axis directly
	// instead of receding into depth.
	//
	// UCameraComponent::FieldOfView is the HORIZONTAL fov and stays fixed as
	// aspect ratio changes (engine default AspectRatioAxisConstraint =
	// MaintainXFOV) — so the subtended angle across whichever axis is
	// crosswise to the view direction is what has to match between rigs, not
	// the raw distance. Centred on X=0 (not Team-A's baseline) since a
	// side-on broadcast shot has no "near" team the way an end-zone shot does.
	//
	// VERIFIED 2026-09-02 via MatchFilmer at 1280x720 (this headless setup's
	// Xvfb is fixed at 1280x720 — -resx/-resy and -windowed are both
	// ignored, so a true portrait render couldn't be captured; 1280x720 is
	// landscape and did exercise this rig). A first pass scaled the tuned
	// portrait numbers by CourtHalfLength/CourtHalfWidth (1050->2100,
	// 850->1700) to reproduce the same subtended angle on the longer axis,
	// but that read distant — lots of empty ocean/foreground, court/players
	// small. Tightened both by ~20% (same ~39 deg elevation the portrait rig
	// uses) so the players read at a comparable size to the portrait rig.
	FVector SideCamPos = FVector(0, -1700, 1350);

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

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
