// AI player - volleyball state machine: Receive -> Set -> Attack with proper
// roles, height-aware contacts, and team coordination (no flip-flopping).

enum EPlayerRole { Role_Back, Role_Front }

class AAIPlayer : AVolleyballPlayer
{
	UPROPERTY(BlueprintReadWrite) float Difficulty = 0.75f;
	UPROPERTY(BlueprintReadWrite) EPlayerRole Role = EPlayerRole::Role_Back;
	UPROPERTY() ABall Ball;
	UPROPERTY() AAIPlayer Teammate;  // the other player on this team

	float ReactionDelay = 0.0f;
	float ReactionTimer = 0.0f;

	// True if I made my team's most recent contact — so my teammate takes the
	// next touch (digger != setter != attacker), preventing one player from
	// making all three touches and committing a fourth-touch fault.
	bool bIMadeLastTouch = false;

	// --- Contact-height windows (relative to ball Z) ---
	// Dig:   ball low, near waist/chest      -> bump it up
	// Set:   ball at chest/head height       -> soft high arc
	// Spike: ball above head while airborne  -> drive it down
	const float DigMaxZ   = 130.0f;   // ball below this = dig
	const float SetMinZ   = 110.0f;
	const float SetMaxZ   = 220.0f;
	const float SpikeMinZ = 200.0f;   // need a jump to reach

	void Setup(ETeam Team, EPlayerRole InRole, float InDifficulty,
		ABall InBall, ASandFX InSand, ACourt InCourt, ABeachVolleyballGameMode InGM)
	{
		TeamSide = Team;
		Role = InRole;
		Difficulty = InDifficulty;
		Ball = InBall;
		Sand = InSand;
		Court = InCourt;
		GM = InGM;
		MoveSpeed = 420.0f + Difficulty * 220.0f;
		ReactionDelay = Math::Lerp(0.35f, 0.04f, Difficulty);

		CourtMinY = -450.0f;
		CourtMaxY = 450.0f;
		if (Team == ETeam::Team_A) { CourtMinX = -900.0f; CourtMaxX = -5.0f; }
		else                       { CourtMinX =    5.0f; CourtMaxX = 900.0f; }
	}

	UFUNCTION(BlueprintOverride)
	void BeginPlay()
	{
		InitPlayer();
		CourtMinX = -900.0f; CourtMaxX = -5.0f;
		CourtMinY = -450.0f; CourtMaxY = 450.0f;
	}

	UFUNCTION(BlueprintOverride)
	void Tick(float DeltaTime)
	{
		UpdatePlayer(DeltaTime);
		if (Ball == nullptr) FindBall();
		if (Ball == nullptr || !Ball.bInPlay) return;

		ReactionTimer += DeltaTime;
		if (ReactionTimer < ReactionDelay) return;
		ReactionTimer = 0.0f;

		UpdateAI(DeltaTime);
	}

	// ---------------------------------------------------------------
	// Main decision loop (protected so AHumanPlayer can reuse it as its
	// AI fallback when no gamepad input is active)
	// ---------------------------------------------------------------
	protected void UpdateAI(float DeltaTime)
	{
		// Ball is on the opponent's side: play DEFENSE and clear our touch-ownership
		// so the next receive starts fresh.
		if (!IsBallComingToMySide())
		{
			bIMadeLastTouch = false;
			PlayDefense(DeltaTime);
			return;
		}

		int Touches = TeamTouches();          // how many times WE have touched it
		FVector Landing = Ball.PredictLanding();

		// Decide my job for this contact based on touch count + role
		if (AmIHitter(Landing))
		{
			if (bDebugAI) Log(DebugTag() + " HITTER t=" + Touches + " ballZ=" + int(Ball.Position.Z) + " grounded=" + bIsGrounded);
			PlayHitter(Touches, DeltaTime);
		}
		else
		{
			if (bDebugAI) Log(DebugTag() + " SUPPORT t=" + Touches);
			PlaySupport(Landing, DeltaTime);
		}
	}

	// Temporary diagnostics — set true on ONE player from GameMode to inspect.
	bool bDebugAI = false;
	private FString DebugTag() const
	{
		FString T = (TeamSide == ETeam::Team_A) ? "A" : "B";
		FString R = (Role == EPlayerRole::Role_Front) ? "Front" : "Back";
		return T + "/" + R;
	}

	// ---------------------------------------------------------------
	// Role assignment — deterministic so the two players never swap
	// mid-rally and end up chasing the same ball.
	// ---------------------------------------------------------------
	private bool AmIHitter(FVector Landing) const
	{
		if (Teammate == nullptr) return true;

		// I never take two contacts in a row — if I made the last touch, it's
		// my teammate's turn now. This guarantees digger != setter != attacker.
		if (bIMadeLastTouch) return false;
		if (Teammate.bIMadeLastTouch) return true;

		// Fresh ball coming over (no team touches yet): closest player digs,
		// with the back player favored for deep balls (typical serve receive).
		float MyDist    = (GetActorLocation() - Landing).Size2D();
		float TheirDist = (Teammate.GetActorLocation() - Landing).Size2D();

		bool bDeep = IsDeep(Landing.X);
		if (bDeep && Role == EPlayerRole::Role_Back)  return true;
		if (bDeep && Role == EPlayerRole::Role_Front) return false;

		return MyDist <= TheirDist;
	}

	// ---------------------------------------------------------------
	// I am the player who will contact the ball this touch
	// ---------------------------------------------------------------
	private void PlayHitter(int Touches, float DeltaTime)
	{
		if (Touches >= 2)
		{
			// ATTACK: get under a high ball, jump, and spike at the peak
			ApproachForSpike(DeltaTime);
			return;
		}

		// Decide our intended contact type. A fingerpass (set) is legal only if we
		// can get UNDER the ball with our forehead in time. We judge this against the
		// spot where the ball will be at forehead height (where we're heading) and
		// whether we can plausibly reach that spot before the ball arrives — not the
		// ball's current position, which is still mid-flight when we decide.
		EHitType Intend;
		if (Touches == 0)
		{
			Intend = EHitType::Hit_Bump;   // first touch (receive) is always a dig
		}
		else
		{
			float ForeheadZ = GetActorLocation().Z + PlayerHeight * 0.9f;
			// Where the ball will be when it drops to forehead height.
			FVector SetSpot = PredictBallAtHeight(ForeheadZ);
			float DistToSetSpot = (GetActorLocation() - FVector(SetSpot.X, SetSpot.Y, 0)).Size2D();
			// Will the ball actually descend to forehead height (i.e. is it high
			// enough to set), and can we get under that spot in time?
			bool bBallSettable = SetSpot.Z >= ForeheadZ - 20.0f;
			bool bCanGetUnder = DistToSetSpot < UnderBallRadius;
			Intend = (bBallSettable && bCanGetUnder) ? EHitType::Hit_Set : EHitType::Hit_Bump;
		}

		// Aim where we want to send it (sets the bounce direction for contact).
		if (Intend == EHitType::Hit_Bump) DoDig();
		else                              DoSet();

		// Stand where the ball will be when it drops to PLAY height (waist/chest),
		// not at its ground landing spot. A bagger meets the ball ~1m up while it's
		// still travelling, so aiming at the Z=0 landing point leaves us a metre
		// short horizontally — exactly the gap the debug meter showed (~105cm).
		FVector PlaySpot = PredictBallAtHeight(ContactHeight());
		FVector Goal = ClampToCourt(FVector(PlaySpot.X, PlaySpot.Y, 0));
		float DistToGoal = (GetActorLocation() - Goal).Size2D();

		// Close all the way in — a small plant radius so we actually arrive under
		// the ball rather than stopping a half-metre short.
		if (DistToGoal > PlantRadius)
			MoveToward2D(Goal, DeltaTime);
		else
			MovePlayer(FVector2D::ZeroVector);

		// Always face the ball while playing it, so "in front of the chest" actually
		// points at the ball and the IK platform meets it.
		FaceBall();

		// Prepare the swing EARLY: start reaching/winding up well before the ball
		// arrives so the gesture (especially the spike's cock->strike) is fully
		// built up at contact instead of a last-frame snap. The IK eases the pose
		// in smoothly and actual contact is governed by hand-to-ball distance, so
		// reaching early has no downside — only a more readable, prepared motion.
		float BallDist = (GetActorLocation() - Ball.Position).Size();
		if (BallDist < PrepareDistance)
			Reach(Intend);
	}

	// Distance at which we START preparing the swing/arms. Generous so the wind-up
	// has time to develop before the ball gets here.
	const float PrepareDistance = 280.0f;

	// How close (cm) we must be to the landing spot before we plant and reach.
	const float PlantRadius = 60.0f;

	// How close (horizontally, cm) we must be under the ball to use a fingerpass
	// (set). Beyond this we're not under it in time and must bagger instead.
	const float UnderBallRadius = 70.0f;

	// The world Z at which we want to meet the ball — roughly chest height, where a
	// bagger platform contacts it.
	private float ContactHeight() const
	{
		return GetActorLocation().Z + PlayerHeight * 0.4f;
	}

	// Simulate the ball forward and return its (X,Y,Z) when it next descends to the
	// given height. If it never reaches that height (already below / rising away),
	// fall back to the ground landing prediction.
	private FVector PredictBallAtHeight(float TargetZ) const
	{
		FVector P = Ball.Position;
		FVector V = Ball.BallVel;
		const float G = -980.0f;
		const float Dt = 0.02f;
		float T = 0.0f;
		while (T < 3.0f)
		{
			V.Z += G * Dt;
			FVector Next = P + V * Dt;
			// Detect a downward crossing of TargetZ between P and Next.
			if (P.Z >= TargetZ && Next.Z <= TargetZ && V.Z < 0.0f)
				return Next;
			P = Next;
			T += Dt;
			if (P.Z <= 0.0f) break;
		}
		return Ball.PredictLanding();
	}

	private void FaceBall()
	{
		// Request facing via the single rotation authority (UpdatePlayer lerps to it)
		// rather than snapping the rotation here — snapping fought the travel-facing
		// and caused jerky spinning, especially mid-jump.
		FVector To = Ball.Position - GetActorLocation();
		To.Z = 0;
		if (To.SizeSquared() > 1.0f)
		{
			FacingDir = To.GetSafeNormal();
			bHasFacing = true;
		}
	}

	// ---------------------------------------------------------------
	// I am NOT contacting this touch — get to the right support spot.
	// Crucially, anticipate MY upcoming touch in the three-touch rhythm:
	//  - after our receive (1 touch), I'll be the setter -> go to the setter zone
	//  - after our set (2 touches), I'll be the attacker -> go to the net to spike
	// so I'm already in position when the ball comes to me.
	// ---------------------------------------------------------------
	private void PlaySupport(FVector Landing, float DeltaTime)
	{
		int Touches = TeamTouches();
		float Sign = MySign();
		FVector Target;

		if (Touches == 1)
		{
			// Our receive is up; I set next. Go to the SAME setter zone the receive
			// was aimed at (central, off the net) so I'm under the ball to set.
			Target = SetterZone();
		}
		else if (Touches == 2)
		{
			// Our set is up; I attack. Get to the net under the set so I can spike.
			Target = FVector(Sign * 150.0f, Landing.Y, FloorZ + PlayerHeight);
		}
		else
		{
			Target = SupportPos(Landing);
		}

		// Always keep at least MinSeparation from my teammate so our team holds two
		// distinct options: whoever gets the ball can attack into open space OR pass
		// to the well-separated partner. Push my target away from the teammate along
		// the line between us until we're far enough apart.
		Target = SpreadFromTeammate(Target);

		// Take the spot and HOLD it (no constant shuffling), facing the play.
		MoveToHold(ClampToCourt(Target), DeltaTime);
		FaceAttacker();
	}

	// Turn to face whichever teammate/opponent is about to attack (or the ball), so
	// we're oriented into the play while standing still.
	private void FaceAttacker()
	{
		// Same single-authority facing request (smooth lerp in UpdatePlayer).
		FVector Look = Ball.Position - GetActorLocation();
		Look.Z = 0;
		if (Look.SizeSquared() > 1.0f)
		{
			FacingDir = Look.GetSafeNormal();
			bHasFacing = true;
		}
	}

	// Minimum desired distance between teammates: about half the court width, so an
	// attacker always has a spike option AND a clearly separated pass option.
	const float MinSeparation = 450.0f;   // ~half of the 900cm-wide court

	// Nudge a desired position away from my teammate so we end up at least
	// MinSeparation apart. Keeps the original spot when we're already spread.
	private FVector SpreadFromTeammate(FVector Desired) const
	{
		if (Teammate == nullptr) return Desired;
		FVector Mate = Teammate.GetActorLocation();
		FVector Away = FVector(Desired.X - Mate.X, Desired.Y - Mate.Y, 0);
		float Dist = Away.Size2D();
		if (Dist >= MinSeparation) return Desired;          // already far enough

		// Too close: move out to MinSeparation along the away direction. If we're
		// almost on top of each other, push along Y (down the court) by default.
		FVector Dir = (Dist > 1.0f) ? Away.GetSafeNormal2D() : FVector(0, 1, 0);
		FVector Spread = Mate + Dir * MinSeparation;
		return FVector(Spread.X, Spread.Y, Desired.Z);
	}

	// ---------------------------------------------------------------
	// Spike approach: time the jump so contact happens at the top
	// ---------------------------------------------------------------
	private void ApproachForSpike(float DeltaTime)
	{
		// Stand just behind the net under the ball's current X, ready to swing
		FVector UnderBall = FVector(Ball.Position.X, Ball.Position.Y, FloorZ + PlayerHeight);
		UnderBall = ClampToCourt(UnderBall);
		MoveToward2D(UnderBall, DeltaTime);

		float Horiz = (GetActorLocation() - FVector(Ball.Position.X, Ball.Position.Y, 0)).Size2D();
		float BallZ = Ball.Position.Z;

		// Jump when the ball is high, descending into strike range, and we're under it
		if (bIsGrounded && Horiz < 130.0f && BallZ > SpikeMinZ && Ball.BallVel.Z < 120.0f)
			Jump();

		// Prepare the spike EARLY: as soon as we're approaching (and the ball is up),
		// start winding up — face the ball, aim, and cock the arm — so the swing is
		// loaded by the time we strike instead of snapping at the last moment.
		if (Horiz < PrepareDistance && BallZ > 150.0f)
		{
			FaceBall();
			DoSpike();
			Reach(EHitType::Hit_Spike);
		}
	}

	// ---------------------------------------------------------------
	// Contacts — the ball now physically bounces off the player. These set the
	// AIM target so OnBallContact (on the base player) knows where to send it.
	// ---------------------------------------------------------------
	// The shared setter target: where a receive lands and where the setter goes.
	// Central in Y (0) so the second-ball attack can go either direction, and a bit
	// off the net (so the set has room) — a high, central, attackable second ball.
	private FVector SetterZone() const
	{
		return FVector(MySign() * SetterZoneX, 0.0f, FloorZ + PlayerHeight);
	}
	const float SetterZoneX = 280.0f;

	private void DoDig()
	{
		// Receive: pop the ball UP and OVER THE MIDDLE to the setter zone with a high
		// arc, so the teammate has time to get under it and can then attack to either
		// side. Aiming through the centre (Y=0) is what makes the 2nd-ball attack easy.
		FVector Zone = SetterZone();
		AimAt(FVector(Zone.X, Zone.Y, 420.0f));
	}

	private void DoSet()
	{
		// Set: high arc to the attacker near the net so they can approach and spike.
		// Aim where the attacker WILL be (their net position), high enough to hit.
		float Sign = MySign();
		FVector AttackSpot = (Teammate != nullptr && Teammate.Role == EPlayerRole::Role_Front)
			? FVector(Sign * 120.0f, Teammate.GetActorLocation().Y, FloorZ + PlayerHeight)
			: FVector(Sign * 120.0f, Ball.Position.Y * 0.4f, FloorZ + PlayerHeight);
		AimAt(AttackSpot + FVector(0, 0, 380.0f));
	}

	private void DoSpike()
	{
		// Aim down into the opponent's open court; OnBallContact forces the angle.
		AimAt(PickAttackTarget());
	}

	// Tell the base player where to send the ball on the next physical contact.
	private void AimAt(FVector WorldTarget)
	{
		DesiredAim = WorldTarget;
		bHasAim = true;
	}

	// Aim for the opponent's open court, away from their players
	private FVector PickAttackTarget() const
	{
		float OppSign = -MySign();
		float TargetX = OppSign * Math::Lerp(350.0f, 700.0f, Difficulty);

		// Aim to whichever Y half is less defended — approximate by aiming
		// opposite our own attacker's Y, with error that shrinks with skill
		float AimY = (GetActorLocation().Y > 0) ? -250.0f : 250.0f;
		float Error = Math::RandRange(-180.0f, 180.0f) * (1.0f - Difficulty);
		AimY = Math::Clamp(AimY + Error, CourtMinY + 60.0f, CourtMaxY - 60.0f);

		return FVector(TargetX, AimY, FloorZ + BallRadiusGuess());
	}

	private float BallRadiusGuess() const { return (Ball != nullptr) ? Ball.BallRadius : 10.5f; }

	// ---------------------------------------------------------------
	// Positioning helpers
	// ---------------------------------------------------------------
	private FVector SupportPos(FVector Landing) const
	{
		float Sign = MySign();
		if (Role == EPlayerRole::Role_Front)
		{
			// Front player: stay at net ready to attack, track ball Y
			float Y = Math::Clamp(Landing.Y, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(Sign * 170.0f, Y, FloorZ + PlayerHeight);
		}
		else
		{
			// Back player: cover deep court behind the attacker
			float Y = Math::Clamp(Landing.Y * 0.5f, CourtMinY + 100.0f, CourtMaxY - 100.0f);
			return FVector(Sign * 620.0f, Y, FloorZ + PlayerHeight);
		}
	}

	// ---------------------------------------------------------------
	// Defense: the ball is on the opponent's side. Two defenders split the court
	// (one covers each Y half) UNLESS it's a clear jump-spike threat at the net —
	// then the front player blocks at the net and the back player covers the line
	// behind the block.
	// ---------------------------------------------------------------
	private void PlayDefense(float DeltaTime)
	{
		FVector Goal;
		AAIPlayer Attacker = FindAttackingOpponent();
		// Default assumption: the opponent WILL spike, so we commit to the block.
		// We only drop OFF the block once their pass/set turns out to be poor (too
		// far off the net or too low to attack) — then there's nothing to block and
		// we fall back into court defense.
		bool bAttackable = IsPassAttackable();

		if (Role == EPlayerRole::Role_Front && bAttackable)
		{
			// COMMIT TO BLOCK: get to the net in line with the ball, then jump and
			// throw the hands up. We position to the BALL's Y (where the spike comes
			// from), aim the block toward the middle of the opponent's court, and —
			// crucially — once airborne we STOP repositioning so we don't drift in
			// the air; the IK reaches the hands to the ball.
			float NetX = MySign() * 55.0f;   // right up at the net on our side
			float BlockY = Math::Clamp(Ball.Position.Y, CourtMinY + 60.0f, CourtMaxY - 60.0f);
			Goal = FVector(NetX, BlockY, FloorZ + PlayerHeight);

			// Aim the block at the middle of the opponent's court so a stuffed ball
			// drops there (DesiredAim drives the hand angle in UpdateIKTargets).
			AimAt(FVector(-MySign() * 300.0f, 0.0f, FloorZ));

			if (bIsGrounded)
			{
				// On the ground: move into position, then jump when the strike is near.
				float Horiz = (GetActorLocation() - FVector(Goal.X, Goal.Y, 0)).Size2D();
				if (Horiz < 90.0f && Ball.Position.Z > SpikeMinZ && Ball.BallVel.Z < 150.0f)
					Jump();
				MoveToward2D(Goal, DeltaTime);
			}
			else
			{
				// Airborne: hold still (no drift) and throw up the block.
				MovePlayer(FVector2D::ZeroVector);
			}
			Reach(EHitType::Hit_Block);
			if (bDebugAI) Log(DebugTag() + " DEFEND BLOCK ballZ=" + int(Ball.Position.Z) + " air=" + !bIsGrounded);
			return;
		}
		else if (Role == EPlayerRole::Role_Back && bAttackable)
		{
			// Back defender covers deep behind the block, toward the open court the
			// blocker isn't taking away.
			float DeepX = MySign() * 600.0f;
			float CoverY = (Attacker != nullptr)
				? Math::Clamp(-Attacker.GetActorLocation().Y * 0.6f, CourtMinY + 80.0f, CourtMaxY - 80.0f)
				: 0.0f;
			Goal = FVector(DeepX, CoverY, FloorZ + PlayerHeight);
		}
		else
		{
			// Pass was poor / no attack coming — drop off the block and split the
			// court so each defender owns a Y half at a FIXED defensive spot. No
			// per-frame leaning toward the ball: that caused constant shuffling.
			// Stand still on your half and react only when the ball comes over.
			float Depth = (Role == EPlayerRole::Role_Front) ? MySign() * 250.0f : MySign() * 560.0f;
			float HalfCenter = (Role == EPlayerRole::Role_Front) ? -200.0f : 200.0f;
			Goal = FVector(Depth, HalfCenter, FloorZ + PlayerHeight);
		}

		if (bDebugAI) Log(DebugTag() + " DEFEND " + (bAttackable ? "BLOCK/COVER" : "SPLIT")
			+ " ballX=" + int(Ball.Position.X) + " ballZ=" + int(Ball.Position.Z));
		// Take the defensive spot and HOLD it, facing the play.
		MoveToHold(ClampToCourt(Goal), DeltaTime);
		FaceAttacker();
	}

	// Find the opponent who is about to hit — the one closest to the ball on the
	// other side of the net.
	private AAIPlayer FindAttackingOpponent() const
	{
		TArray<AActor> Players;
		GetAllActorsOfClass(AVolleyballPlayer, Players);
		AAIPlayer Best = nullptr;
		float BestDist = 99999.0f;
		for (AActor A : Players)
		{
			AAIPlayer P = Cast<AAIPlayer>(A);
			if (P == nullptr || P.TeamSide == TeamSide) continue;   // only opponents
			float D = (P.GetActorLocation() - Ball.Position).Size();
			if (D < BestDist) { BestDist = D; Best = P; }
		}
		return Best;
	}

	// Remembered block/drop decision, with HYSTERESIS so it doesn't flip every frame
	// (which made players run back and forth). Once committed to the block we hold it
	// until the pass is CLEARLY un-attackable; once dropped we don't re-commit until
	// the ball is CLEARLY attackable again. The two thresholds don't overlap.
	private bool bCommittedToBlock = false;

	private bool IsPassAttackable()
	{
		float BallOffNet = Math::Abs(Ball.Position.X);
		float BallZ = Ball.Position.Z;
		bool bOpponentSide = (TeamSide == ETeam::Team_A) ? Ball.Position.X > -50.0f
		                                                 : Ball.Position.X <  50.0f;

		if (!bOpponentSide)
		{
			bCommittedToBlock = false;
			return false;
		}

		if (bCommittedToBlock)
		{
			// Stay on the block until the pass is clearly bad: well off the net OR
			// dropped low. Wide margins so small ball motion doesn't drop the block.
			if (BallOffNet > 420.0f || BallZ < 110.0f)
				bCommittedToBlock = false;
		}
		else
		{
			// Commit to the block only when the ball is clearly a real attack setup:
			// near the net and high. Tighter than the drop thresholds (hysteresis gap).
			if (BallOffNet < 300.0f && BallZ > 170.0f)
				bCommittedToBlock = true;
		}

		return bCommittedToBlock;
	}

	// ---------------------------------------------------------------
	// Queries
	// ---------------------------------------------------------------
	private float MySign() const { return (TeamSide == ETeam::Team_A) ? -1.0f : 1.0f; }

	private int TeamTouches() const
	{
		ABeachVolleyballGameState GS = Cast<ABeachVolleyballGameState>(GetWorld().GetGameState());
		if (GS == nullptr) return 0;
		// Only count touches that belong to our team this rally
		if (GS.LastTouchTeam == TeamSide) return GS.TouchesThisRally;
		return 0;  // ball just crossed to us — this is our receive (touch 0)
	}

	// Should our team actively go play the ball right now? Only when the ball is
	// genuinely on our side of the net — not while it's still high over the
	// opponent's court (even if it's predicted to eventually cross to us).
	private bool IsBallComingToMySide() const
	{
		bool bBallOnMySide = (TeamSide == ETeam::Team_A) ? Ball.Position.X <= 0.0f
		                                                 : Ball.Position.X >= 0.0f;

		// If the ball is physically on our side, it's ours to play.
		if (bBallOnMySide) return true;

		// Ball is on the opponent's side. Only commit early if it has clearly
		// crossed toward us (moving to our side AND already low enough that the
		// predicted landing is on our court) — otherwise hold and defend.
		bool bMovingToMe = (TeamSide == ETeam::Team_A) ? Ball.BallVel.X < -50.0f
		                                               : Ball.BallVel.X >  50.0f;
		if (!bMovingToMe) return false;

		FVector Landing = Ball.PredictLanding();
		bool bLandMine = (TeamSide == ETeam::Team_A) ? Landing.X <= 0.0f
		                                             : Landing.X >= 0.0f;
		// Require the ball to be near or past the net before charging in.
		bool bNearNet = Math::Abs(Ball.Position.X) < 250.0f;
		return bLandMine && bNearNet;
	}

	private bool IsDeep(float X) const
	{
		if (TeamSide == ETeam::Team_A) return X < -350.0f;
		return X > 350.0f;
	}

	// Horizontal reach to the ball's current position
	private bool IsWithinReach() const
	{
		FVector ToBall = Ball.Position - GetActorLocation();
		return ToBall.Size2D() < 110.0f;
	}

	private FVector ClampToCourt(FVector P) const
	{
		return FVector(
			Math::Clamp(P.X, CourtMinX + 40.0f, CourtMaxX - 40.0f),
			Math::Clamp(P.Y, CourtMinY + 40.0f, CourtMaxY - 40.0f),
			FloorZ + PlayerHeight);
	}

	// ---------------------------------------------------------------
	// Movement (no auto-jump here — jumping is decided by spike logic)
	// ---------------------------------------------------------------
	private void MoveToward2D(FVector Target, float Dt)
	{
		FVector Dir = Target - GetActorLocation();
		Dir.Z = 0;
		if (Dir.Size2D() > 8.0f)
			MovePlayer(FVector2D(Dir.GetSafeNormal2D().X, Dir.GetSafeNormal2D().Y));
		else
			MovePlayer(FVector2D::ZeroVector);
	}

	// Positional "hold": move to the target, but once we arrive STAY PUT until the
	// target drifts well away. This kills the constant micro-shuffling during
	// defense/support — you take your spot, face up, and stand still. Hysteresis:
	// start moving only past StartMoving, stop as soon as within Arrived.
	private bool bHolding = false;
	private void MoveToHold(FVector Target, float Dt)
	{
		const float StartMoving = 110.0f;   // must drift this far before we re-chase
		const float Arrived     = 35.0f;    // close enough — plant and hold
		float D = (Target - GetActorLocation()).Size2D();

		if (bHolding)
		{
			if (D > StartMoving) bHolding = false;   // target moved a lot; reposition
		}
		else
		{
			if (D <= Arrived) bHolding = true;        // arrived; lock in place
		}

		if (bHolding)
			MovePlayer(FVector2D::ZeroVector);        // stand still
		else
			MoveToward2D(Target, Dt);
	}

	// ---------------------------------------------------------------
	// The base player registers the touch when the ball physically bounces off
	// us; we just record that it was us, so the teammate takes the next contact.
	void OnTouchRegistered() override
	{
		bIMadeLastTouch = true;
		if (Teammate != nullptr)
			Teammate.bIMadeLastTouch = false;
	}

	// No two contacts in a row — I'm transparent to the ball right after I hit it.
	bool CanContactBall() const override
	{
		return !bIMadeLastTouch;
	}

	protected void FindBall()
	{
		TArray<AActor> Found;
		GetAllActorsOfClass(ABall, Found);
		if (Found.Num() > 0)
			Ball = Cast<ABall>(Found[0]);
	}
}
