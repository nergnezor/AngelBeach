// End-zone camera: fixed behind Team A's baseline, tilts up to follow the ball
class ABeachVolleyballCamera : AActor
{
	UPROPERTY(DefaultComponent, RootComponent)
	UCameraComponent CameraComp;

	// Fixed camera behind Team A's baseline, looking down the length of the court.
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
	FVector CamPos = FVector(-1050, 0, 850);

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

	private void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
