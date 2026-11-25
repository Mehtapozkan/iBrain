# iBrain

A Swift package for connecting people, places, dates and events while retaining the records that support each relationship.

[Project website](https://mehtapozkan.github.io/iBrain/) · [Download Swift source](https://mehtapozkan.github.io/iBrain/iBrain-source.zip)

## Connect facts across records

Represent the person in an appointment, its venue, date and time as related entities. Pin can display those details together and lead the reader back to the evidence for each.

## Carry corrections through an answer

When a time changes, the engine tracks the evidence for the revision. A removed venue quote can invalidate an appointment claim. A disputed clock can no longer support a change explanation.

## Keep uncertainty visible

A missing source leaves a relationship unresolved. A confirmed performer can still be represented when evidence for a second possible performer is unavailable.

## Use it in Swift

The distribution contains IBrain, IBrainSemantics, IBrainRetrieval and IBrainVision. Unzip it and run swift test from the iBrain directory. Pin uses this same package as a local dependency.

## Verification

All 186 package tests passed on macOS and on an iPhone Simulator. 

[Pin](https://mehtapozkan.github.io/Pin/) · [iBrain](https://mehtapozkan.github.io/iBrain/) · [Pin-Qwen-6bit](https://mehtapozkan.github.io/Pin-Qwen-6bit/)
