# HomeRescue AI - Project Idea and Business Question

**Problem:** NYC housing agencies have limited maintenance inspection and emergency repair resources. Identifying buildings with a concentration of complaints and hazardous housing-code violations can improve prioritization for further human review.

**Main Question:** Which residential buildings in Staten Island should be prioritized for 2024 housing maintenance review based on reported problems, Class B/C hazard violations, unresolved violations and eligible Open Market Order repair awards?

**Data:** Four publicly available NYC Department of Housing Preservation and Development (HPD) datasets: Buildings (`kj4p-ruqc`), Complaints & Problems (`ygpa-z7cr`), Violations (`wvxf-dwi5`), OMO Charges (`mdbu-nrqn`).

**Bronze:** Store raw source columns as text with input provenance (batch ID, source ID/file, load time).

**Silver:** Normalize IDs, safely convert dates/numbers, identify invalid or duplicate rows, record rejects, reconcile Bronze to Silver.

**Gold:** Persistent building/date dimensions, atomic complaint/violation/repair order facts, building-month aggregates, descriptive maintenance priority features, and semantic analytics.

**Business output:** Rank buildings using an interpretable SQL score, identify hazardous buildings without eligible OMO orders, and summarize complaint, violation and award exposure by geography and month.

**Priority-score formula (as implemented in `sql/05_feature_views.sql`):**
`Score = 5 * Class C count + 3 * Class B count + 2 * Open violations + 4 * Rent-impairing violations + 1 * Emergency problems`.

**Important limitations:** This is a descriptive prioritization index, **not** a trained machine-learning probability or causal evidence. OMO award amounts are contracted award commitments, **not** actual paid invoices or cost savings.
