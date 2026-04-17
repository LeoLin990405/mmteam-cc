# Example: Fanout Consensus

Send the same question to multiple models and analyze agreement.

## Setup

```bash
mmteam create cmp kimi:kimi-code gpt:codex gem:gemini
mmteam a2a spawn cmp
```

## Run

```bash
# Factual question — 3 models vote
mmteam a2a fanout cmp "Is 91 a prime number? Answer ONLY 'prime' or 'composite'." \
  --agents kimi,gpt,gem --json | jq .

# Output includes:
# - Each agent's response
# - Pairwise Jaccard similarity matrix (CJK bigram tokenization)
# - Outlier detection (replies that diverge from group)
# - Consensus summary
```

## With LLM-as-judge

```bash
# Let gemini synthesize all 3 answers into a final verdict
mmteam a2a fanout cmp "Explain the CAP theorem in 3 bullet points" \
  --agents kimi,gpt,gem --judge gem
```

## When to use fanout

- Factual verification (multi-model voting)
- A/B testing code implementations
- Exploring different approaches to a design problem
- Detecting model-specific blind spots

## Cleanup

```bash
mmteam a2a stop cmp && mmteam destroy cmp
```
