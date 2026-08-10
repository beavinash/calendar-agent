"""Deterministic follow-through estimates for calendar review evidence."""

from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum

from app.schemas.agent import CalendarEventSnapshot, CompletionStatus

UNMARKED_INCOMPLETE_PROBABILITY = 0.7


class CompletionEvidenceBasis(StrEnum):
  """Why an event has or does not have an incomplete probability."""

  EXPLICIT_COMPLETE = "explicit_complete"
  EXPLICIT_INCOMPLETE = "explicit_incomplete"
  INFERRED_UNMARKED_ELAPSED = "inferred_unmarked_elapsed"
  EXCLUDED_NOT_ENDED = "excluded_not_ended"
  EXCLUDED_BEFORE_TRACKING = "excluded_before_tracking"


@dataclass(frozen=True, slots=True)
class FollowThroughEstimate:
  """One event's incomplete probability and its evidence basis."""

  incomplete_probability: float | None
  basis: CompletionEvidenceBasis


@dataclass(frozen=True, slots=True)
class FollowThroughSummary:
  """Aggregate explicit outcomes and inferred likely misses."""

  explicit_complete_count: int
  explicit_incomplete_count: int
  inferred_unmarked_count: int
  estimated_incomplete_weight: float

  @property
  def eligible_count(self) -> int:
    """Return events that contribute explicit or inferred evidence."""

    return (
      self.explicit_complete_count
      + self.explicit_incomplete_count
      + self.inferred_unmarked_count
    )


def estimate_follow_through(
  event: CalendarEventSnapshot,
  current_time: datetime,
  tracking_started_at: datetime,
) -> FollowThroughEstimate:
  """Apply the 0%, 70%, 100% rule without mutating recorded state."""

  if event.start_at > current_time:
    return FollowThroughEstimate(
      incomplete_probability=None,
      basis=CompletionEvidenceBasis.EXCLUDED_NOT_ENDED,
    )
  if event.completion_status == CompletionStatus.COMPLETE:
    return FollowThroughEstimate(
      incomplete_probability=0.0,
      basis=CompletionEvidenceBasis.EXPLICIT_COMPLETE,
    )
  if event.completion_status == CompletionStatus.INCOMPLETE:
    return FollowThroughEstimate(
      incomplete_probability=1.0,
      basis=CompletionEvidenceBasis.EXPLICIT_INCOMPLETE,
    )
  if event.end_at > current_time:
    return FollowThroughEstimate(
      incomplete_probability=None,
      basis=CompletionEvidenceBasis.EXCLUDED_NOT_ENDED,
    )
  if event.end_at < tracking_started_at:
    return FollowThroughEstimate(
      incomplete_probability=None,
      basis=CompletionEvidenceBasis.EXCLUDED_BEFORE_TRACKING,
    )
  return FollowThroughEstimate(
    incomplete_probability=UNMARKED_INCOMPLETE_PROBABILITY,
    basis=CompletionEvidenceBasis.INFERRED_UNMARKED_ELAPSED,
  )


def summarize_follow_through(
  events: list[CalendarEventSnapshot],
  current_time: datetime,
  tracking_started_at: datetime,
) -> FollowThroughSummary:
  """Summarize event estimates with stable floating-point output."""

  complete = 0
  incomplete = 0
  inferred = 0
  estimated_weight = 0.0
  for event in events:
    estimate = estimate_follow_through(
      event,
      current_time,
      tracking_started_at,
    )
    if estimate.basis == CompletionEvidenceBasis.EXPLICIT_COMPLETE:
      complete += 1
    elif estimate.basis == CompletionEvidenceBasis.EXPLICIT_INCOMPLETE:
      incomplete += 1
    elif estimate.basis == CompletionEvidenceBasis.INFERRED_UNMARKED_ELAPSED:
      inferred += 1
    if estimate.incomplete_probability is not None:
      estimated_weight += estimate.incomplete_probability

  return FollowThroughSummary(
    explicit_complete_count=complete,
    explicit_incomplete_count=incomplete,
    inferred_unmarked_count=inferred,
    estimated_incomplete_weight=round(estimated_weight, 6),
  )
