<!--
Copyright: Ankitects Pty Ltd and contributors
License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
-->
<script lang="ts">
    import { TagMasteryResponse_HowSure } from "@generated/anki/stats_pb";
    import type { TagMasteryResponse } from "@generated/anki/stats_pb";
    import { tagMastery } from "@generated/backend";
    import * as tr from "@generated/ftl";
    import { Timestamp } from "@tslib/time";

    import type {
        Category,
        FsrsCategorySummary,
        FsrsSummary,
        Performance,
        PracticeHistoryItem,
        Readiness,
    } from "../practice/mcatMetrics";
    import {
        CATEGORIES,
        computePerformance,
        computeReadiness,
    } from "../practice/mcatMetrics";

    // Group by AAMC section. MileDown is single-rooted under "MileDown::", so
    // the sections live at depth 2 (MileDown::Behavioral, MileDown::Biochemistry,
    // ...); depth 1 would collapse everything into one "MileDown" topic.
    const groupDepth = 2;

    // ── Memory (per-topic recall) ───────────────────────────────────────
    let data: TagMasteryResponse | null = null;

    // ── Performance + Readiness (the other two scores) ──────────────────
    // Performance answers come from the Practice bank's review log; Readiness
    // blends per-section Performance with FSRS mastery. Both used to live on the
    // Practice page — they're now consolidated here so all three scores share
    // one screen.
    interface PracticeAnswer {
        client_answer_id: string;
        question_id: string;
        category: Category;
        correct: boolean;
        difficulty_b: number;
        answered_at: number;
    }

    let performance: Performance | null = null;
    let readiness: Readiness | null = null;
    let fsrsSummary: FsrsSummary | null = null;

    const categoryLabels: Record<Category, string> = {
        bio_biochem: "Bio/Biochem",
        chem_phys: "Chem/Phys",
        psych_soc: "Psych/Soc",
        cars: "CARS",
    };

    async function load(): Promise<void> {
        // masteredThreshold 0 -> backend default (echoed back as thresholdUsed).
        // Empty search -> whole collection.
        data = await tagMastery({ groupDepth, masteredThreshold: 0, search: "" });
    }

    async function loadPerformance(): Promise<void> {
        try {
            const resp = await fetch("/_anki/practiceHistory");
            if (!resp.ok) {
                return;
            }
            const json = (await resp.json()) as { records: PracticeAnswer[] };
            const items: PracticeHistoryItem[] = (json.records ?? []).map((r) => ({
                question_id: r.question_id,
                category: r.category,
                correct: r.correct,
                difficulty_b: r.difficulty_b,
            }));
            performance = computePerformance(items);
            recomputeReadiness();
        } catch (e) {
            // Performance is best-effort; leave it null (shows nothing) on failure.
        }
    }

    function recomputeReadiness(): void {
        if (!performance || !fsrsSummary) {
            return;
        }
        readiness = computeReadiness(performance, fsrsSummary);
    }

    // Maps a MileDown::<Section> tag to one of the 4 canonical categories via
    // case-insensitive substring match. Order matters: bio_biochem before
    // chem_phys so "Biochemistry" isn't misrouted. Unmatched tags are skipped.
    function tagToCategory(tag: string): Category | null {
        const t = tag.toLowerCase();
        if (t.includes("biochem") || t.includes("biology") || t.includes("bio")) {
            return "bio_biochem";
        }
        if (t.includes("chem") || t.includes("physics") || t.includes("phys")) {
            return "chem_phys";
        }
        if (
            t.includes("psych") ||
            t.includes("behavior") ||
            t.includes("social") ||
            t.includes("soc")
        ) {
            return "psych_soc";
        }
        if (t.includes("cars") || t.includes("critical") || t.includes("reading")) {
            return "cars";
        }
        return null;
    }

    function buildFsrsSummary(masteryData: TagMasteryResponse): FsrsSummary {
        const per_category: FsrsCategorySummary[] = CATEGORIES.map((category) => {
            const matched = masteryData.groups.filter(
                (g) => tagToCategory(g.tag) === category,
            );
            const cardsWithState = matched.reduce(
                (sum, g) => sum + g.cardsWithState,
                0,
            );
            if (cardsWithState === 0) {
                return {
                    category,
                    average_recall: 0,
                    mastered_fraction: 0,
                    enough_data: false,
                    graded_reviews: 0,
                };
            }
            const masteredCards = matched.reduce((sum, g) => sum + g.masteredCards, 0);
            const gradedReviews = matched.reduce((sum, g) => sum + g.gradedReviews, 0);
            const weightedRecall =
                matched.reduce(
                    (sum, g) => sum + g.averageRecall * g.cardsWithState,
                    0,
                ) / cardsWithState;
            return {
                category,
                average_recall: weightedRecall,
                mastered_fraction: masteredCards / cardsWithState,
                enough_data: cardsWithState >= 20,
                graded_reviews: gradedReviews,
            };
        });
        return { per_category, overall_mean_recall: masteryData.overallMeanRecall };
    }

    async function loadFsrsSummary(): Promise<void> {
        try {
            const summaryData = await tagMastery({
                groupDepth,
                masteredThreshold: 0,
                // Exclude MCAT practice/palace cards so they never perturb the
                // Readiness figure (which reflects the study deck only).
                search: "-tag:mcat_practice -tag:mcat_palace",
            });
            fsrsSummary = buildFsrsSummary(summaryData);
            recomputeReadiness();
        } catch (e) {
            fsrsSummary = {
                per_category: CATEGORIES.map((category) => ({
                    category,
                    average_recall: 0,
                    mastered_fraction: 0,
                    enough_data: false,
                    graded_reviews: 0,
                })),
                overall_mean_recall: 0,
            };
            recomputeReadiness();
        }
    }

    load();
    loadPerformance();
    loadFsrsSummary();

    const pct = (n: number): string => `${(n * 100).toFixed(1)}%`;
    const pctInt = (n: number): string => `${Math.round(n * 100)}%`;

    function howSureLabel(howSure: TagMasteryResponse_HowSure): string {
        switch (howSure) {
            case TagMasteryResponse_HowSure.HIGH:
                return tr.statisticsMasteryHowSureHigh();
            case TagMasteryResponse_HowSure.MEDIUM:
                return tr.statisticsMasteryHowSureMedium();
            case TagMasteryResponse_HowSure.LOW:
                return tr.statisticsMasteryHowSureLow();
            case TagMasteryResponse_HowSure.INSUFFICIENT:
            default:
                return tr.statisticsMasteryHowSureInsufficient();
        }
    }

    // 0 is the backend's "no graded reviews yet" sentinel - never format it as a date.
    function lastUpdatedText(lastUpdatedSecs: bigint): string {
        const secs = Number(lastUpdatedSecs);
        if (secs === 0) {
            return tr.statisticsMasteryNoReviewsYet();
        }
        const timestamp = new Timestamp(secs);
        return tr.statisticsMasteryLastUpdated({
            when: `${timestamp.dateString()} ${timestamp.timeString()}`,
        });
    }
</script>

<div class="con-root mastery-page">
    {#if data}
        <header class="masthead">
            <span class="unit">MCAT&nbsp;SPEEDRUN</span>
            <span class="sep">/</span>
            <span class="screen">SCORES</span><span class="caret" aria-hidden="true"
            ></span>
        </header>

        <!-- ── MEMORY ─────────────────────────────────────────────── -->
        <section class="panel enter">
            <h2 class="section-header">{tr.statisticsMasteryReadiness()}</h2>
            {#if data.enoughData && data.overallN > 0}
                <div class="readout">
                    <div class="figure">
                        <span class="num" style="color: var(--con-steel)">
                            {pct(data.overallMeanRecall)}
                        </span>
                        <span class="unit-lbl">recall</span>
                    </div>
                    <div class="readout-detail">
                        <div
                            class="scale"
                            style="--lo: {data.overallCiLow}; --hi: {data.overallCiHigh}; --pt: {data.overallMeanRecall}; --scale-accent: var(--con-steel)"
                            role="img"
                            aria-label="likely {pct(data.overallCiLow)} to {pct(
                                data.overallCiHigh,
                            )}"
                        >
                            <div class="track"></div>
                            <div class="band"></div>
                            <div class="marker"></div>
                        </div>
                        <div class="scale-ends">
                            <span>0%</span>
                            <span>
                                {tr.statisticsMasteryLikelyRange()}
                                {pct(data.overallCiLow)} – {pct(data.overallCiHigh)}
                            </span>
                            <span>100%</span>
                        </div>
                    </div>
                </div>
            {:else}
                <div class="readout is-empty">
                    <div class="figure">
                        <span class="num dash">–</span>
                        <span class="unit-lbl">recall</span>
                    </div>
                    <p class="abstain">{tr.statisticsMasteryNotEnoughData()}</p>
                </div>
            {/if}

            <div class="leaders">
                <div class="leader">
                    <span class="k">
                        {tr.statisticsMasteryCoverage({
                            selected: data.topicsCovered,
                            total: data.topicsTotal,
                        })}
                    </span>
                    <span class="d"></span>
                    <span class="v">
                        {data.topicsTotal
                            ? pctInt(data.topicsCovered / data.topicsTotal)
                            : "0%"}
                    </span>
                </div>
                <div
                    class="bar"
                    style="--v: {data.topicsTotal
                        ? data.topicsCovered / data.topicsTotal
                        : 0}"
                    aria-hidden="true"
                >
                    <div class="fill"></div>
                </div>

                {#if data.enoughData && data.overallN > 0}
                    <div class="leader">
                        <span class="k">how sure</span>
                        <span class="d"></span>
                        <span class="v accent">{howSureLabel(data.howSure)}</span>
                    </div>
                    <div class="leader">
                        <span class="k">{tr.statisticsMasteryLikelyRange()}</span>
                        <span class="d"></span>
                        <span class="v">
                            {pct(data.overallCiLow)} – {pct(data.overallCiHigh)}
                        </span>
                    </div>
                {/if}

                <div class="leader">
                    <span class="k">
                        {tr.statisticsMasteryReasons({
                            reviews: data.totalGradedReviews,
                            count: data.topicsWithReviews,
                            total: data.topicsTotal,
                        })}
                    </span>
                    <span class="d"></span>
                    <span class="v muted">{lastUpdatedText(data.lastUpdatedSecs)}</span>
                </div>
            </div>

            {#if data.nextTopic !== ""}
                <div class="next-topic">
                    <span class="tag">▸ study next</span>
                    <span class="topic">{data.nextTopic}</span>
                </div>
            {/if}
        </section>

        <!-- ── PERFORMANCE ────────────────────────────────────────── -->
        {#if performance}
            <section class="panel enter">
                <h2 class="section-header">Performance</h2>
                {#if !performance.overall.enough_data}
                    <p class="abstain">
                        Not enough data yet — answer at least 5 practice questions to
                        see your overall performance.
                    </p>
                {:else}
                    <div class="readout">
                        <div class="figure">
                            <span class="num accent">
                                {pctInt(performance.overall.p)}
                            </span>
                            <span class="unit-lbl">chance correct</span>
                        </div>
                        <div class="readout-detail">
                            <div
                                class="scale"
                                style="--lo: {performance.overall
                                    .p_low}; --hi: {performance.overall
                                    .p_high}; --pt: {performance.overall
                                    .p}; --scale-accent: var(--con-amber)"
                                role="img"
                                aria-label="likely {pctInt(
                                    performance.overall.p_low,
                                )} to {pctInt(performance.overall.p_high)}"
                            >
                                <div class="track"></div>
                                <div class="band"></div>
                                <div class="marker"></div>
                            </div>
                            <div class="scale-ends">
                                <span>0%</span>
                                <span>
                                    likely {pctInt(performance.overall.p_low)} – {pctInt(
                                        performance.overall.p_high,
                                    )} · n={performance.overall.n}
                                </span>
                                <span>100%</span>
                            </div>
                        </div>
                    </div>

                    <div class="cat-rows">
                        {#each performance.per_category as cat (cat.category)}
                            <div class="cat-row" class:muted={!cat.enough_data}>
                                <div class="leader">
                                    <span class="k">{categoryLabels[cat.category]}</span>
                                    <span class="d"></span>
                                    {#if cat.enough_data}
                                        <span class="v">{pctInt(cat.p)}</span>
                                    {:else}
                                        <span class="v dash">—</span>
                                    {/if}
                                </div>
                                {#if cat.enough_data}
                                    <div
                                        class="bar accent"
                                        style="--v: {cat.p}"
                                        aria-hidden="true"
                                    >
                                        <div class="fill"></div>
                                    </div>
                                    <div class="cat-caption">
                                        {pctInt(cat.p_low)}–{pctInt(cat.p_high)} · n={cat.n}
                                    </div>
                                {:else}
                                    <div class="cat-caption">
                                        {cat.n} answer{cat.n === 1 ? "" : "s"} · need 5
                                    </div>
                                {/if}
                            </div>
                        {/each}
                    </div>
                {/if}
            </section>
        {/if}

        <!-- ── READINESS (projected score — the hero readout) ─────── -->
        {#if readiness}
            <section class="panel readiness-panel enter">
                <h2 class="section-header">Readiness</h2>
                {#if !readiness.enough_data || readiness.confidence === "low"}
                    <p class="abstain">
                        {readiness.enough_data
                            ? "Keep answering questions and reviewing cards — there isn't enough confidence in a score estimate yet."
                            : readiness.note}
                    </p>
                {:else}
                    <div class="score-lbl">projected&nbsp;scaled&nbsp;score</div>
                    <div class="score-figure">
                        <span class="score-point">{readiness.score_point}</span>
                        <span class="score-range">
                            likely {readiness.score_low}–{readiness.score_high}
                        </span>
                    </div>
                    <div
                        class="scale big"
                        style="--lo: {(readiness.score_low - 472) /
                            56}; --hi: {(readiness.score_high - 472) /
                            56}; --pt: {(readiness.score_point - 472) /
                            56}; --scale-accent: var(--con-amber)"
                        role="img"
                        aria-label="likely {readiness.score_low} to {readiness.score_high}"
                    >
                        <div class="track"></div>
                        <div class="band"></div>
                        <div class="marker"></div>
                    </div>
                    <div class="scale-ends axis">
                        <span>472</span>
                        <span class="mid">500</span>
                        <span>528</span>
                    </div>
                    <div class="confidence conf-{readiness.confidence}">
                        <span class="dot" aria-hidden="true"></span>
                        {readiness.confidence} confidence
                    </div>
                {/if}
            </section>
        {/if}

        <!-- ── PER-TOPIC TABLE ────────────────────────────────────── -->
        <section class="panel enter">
            <h2 class="section-header">{tr.statisticsMasteryTitle()}</h2>
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr>
                            <th scope="col" class="left">
                                {tr.statisticsMasteryTopic()}
                            </th>
                            <th scope="col">{tr.statisticsMasteryCards()}</th>
                            <th scope="col">{tr.statisticsMasteryScored()}</th>
                            <th scope="col">{tr.statisticsMasteryMastered()}</th>
                            <th scope="col" class="recall-col">
                                {tr.statisticsMasteryAverageRecall()}
                            </th>
                            <th scope="col">{tr.statisticsMasteryReviews()}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {#each data.groups as group (group.tag)}
                            <tr class:untouched={group.cardsWithState === 0}>
                                <td class="left">{group.tag}</td>
                                <td>{group.totalCards}</td>
                                <td>{group.cardsWithState}</td>
                                <td>{group.masteredCards}</td>
                                <td class="recall-col">
                                    {#if group.cardsWithState > 0}
                                        <div
                                            class="recall-bar"
                                            style="--v: {group.averageRecall}"
                                        >
                                            <div class="fill" aria-hidden="true"></div>
                                            <span class="val">
                                                {pct(group.averageRecall)}
                                            </span>
                                        </div>
                                    {:else}
                                        <span class="dash">–</span>
                                    {/if}
                                </td>
                                <td>{group.gradedReviews}</td>
                            </tr>
                        {/each}
                    </tbody>
                </table>
            </div>
            <div class="caption">
                {tr.statisticsMasteryCutoff({
                    percent: Math.round(data.thresholdUsed * 100),
                })}
            </div>
        </section>
    {/if}
</div>

<style lang="scss">
    @use "../../../sass/mcat-tools.scss" as mcat;

    // Honesty: recall visuals use STEEL (neutral). Amber is the interaction /
    // wayfinding accent and is legitimate on Performance & Readiness (scored).
    // Never a red→green scale — colour must not imply "green = ready".

    .mastery-page {
        @include mcat.con-root;
        // Expose tokens as CSS vars for the inline --scale-accent / colours.
        --con-steel: #{mcat.$con-steel};
        --con-amber: #{mcat.$con-amber};

        max-width: 62em;
        margin: 0 auto;
        min-height: 100%;
        padding: clamp(0.9rem, 2.5vw, 1.6rem);
        display: flex;
        flex-direction: column;
        gap: mcat.$mcat-space-md;
    }

    // ── Masthead ────────────────────────────────────────────────────────
    .masthead {
        display: flex;
        align-items: baseline;
        gap: 0.55em;
        font-size: 0.78rem;
        letter-spacing: 0.14em;
        color: mcat.$con-ink-faint;
        padding-bottom: 0.2em;

        .unit {
            color: mcat.$con-ink-dim;
        }
        .screen {
            color: mcat.$con-amber;
            font-weight: 700;
        }
        .caret {
            @include mcat.con-caret;
        }
    }

    // ── Panels ──────────────────────────────────────────────────────────
    .panel {
        @include mcat.con-panel;
        padding: clamp(0.9rem, 2.2vw, 1.35rem);
    }

    .enter {
        @include mcat.con-enter;
        @for $i from 1 through 5 {
            &:nth-of-type(#{$i}) {
                animation-delay: #{$i * 45}ms;
            }
        }
    }

    .section-header {
        @include mcat.con-section-header;
    }

    .abstain {
        color: mcat.$con-ink-dim;
        font-family: mcat.$con-sans;
        font-size: 0.95rem;
        margin: 0.4em 0;
    }

    // ── Readout (big figure + range scale) ──────────────────────────────
    .readout {
        display: flex;
        align-items: center;
        gap: clamp(1rem, 4vw, 2rem);
        flex-wrap: wrap;
        margin-bottom: mcat.$mcat-space-md;

        &.is-empty {
            opacity: 0.85;
        }
    }

    .figure {
        flex: none;
        display: flex;
        flex-direction: column;
        line-height: 1;

        .num {
            font-size: clamp(2.6rem, 8vw, 3.4rem);
            font-weight: 700;
            letter-spacing: -0.02em;

            &.accent {
                color: mcat.$con-amber;
            }
            &.dash {
                color: mcat.$con-ink-faint;
            }
        }

        .unit-lbl {
            margin-top: 0.5em;
            font-size: 0.72rem;
            letter-spacing: 0.14em;
            text-transform: uppercase;
            color: mcat.$con-ink-faint;
        }
    }

    .readout-detail {
        flex: 1;
        min-width: 15em;
    }

    // Shared range-scale device.
    .scale {
        @include mcat.con-scale;

        &.big {
            height: 30px;
            .marker {
                height: 22px;
                top: 4px;
            }
            .track,
            .band {
                top: 11px;
            }
        }
    }

    .scale-ends {
        display: flex;
        justify-content: space-between;
        gap: 1em;
        margin-top: 0.35em;
        font-size: 0.72rem;
        color: mcat.$con-ink-faint;

        span:nth-child(2) {
            color: mcat.$con-ink-dim;
            text-align: center;
        }

        &.axis {
            color: mcat.$con-ink-dim;
            .mid {
                color: mcat.$con-ink-faint;
            }
        }
    }

    // ── Leader rows + bars ──────────────────────────────────────────────
    .leaders {
        display: flex;
        flex-direction: column;
        gap: 0.55em;
        padding-top: 0.75em;
        border-top: 1px solid mcat.$con-line;
    }

    .leader {
        @include mcat.con-leader-row;

        .v.accent {
            color: mcat.$con-amber;
            text-transform: capitalize;
        }
        .v.muted {
            color: mcat.$con-ink-dim;
            font-weight: 400;
        }
        .v.dash {
            color: mcat.$con-ink-faint;
        }
    }

    .bar {
        @include mcat.con-bar(8px);
        margin-top: -0.15em;

        &.accent {
            --bar-fill: #{mcat.$con-amber};
        }
    }

    .next-topic {
        display: inline-flex;
        align-items: center;
        gap: 0.6em;
        align-self: flex-start;
        margin-top: mcat.$mcat-space-md;
        padding: 0.4em 0.75em;
        border: 1px solid mcat.$con-amber-line;
        border-radius: mcat.$con-radius-sm;
        background: mcat.$con-amber-dim;

        .tag {
            font-size: 0.72rem;
            letter-spacing: 0.1em;
            text-transform: uppercase;
            color: mcat.$con-amber;
            font-weight: 700;
        }
        .topic {
            font-size: 0.9rem;
            color: mcat.$con-ink;
        }
    }

    // ── Performance per-category ────────────────────────────────────────
    .cat-rows {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(13em, 1fr));
        gap: mcat.$mcat-space-md 1.5rem;
        margin-top: mcat.$mcat-space-md;
        padding-top: 0.75em;
        border-top: 1px solid mcat.$con-line;
    }

    .cat-row {
        display: flex;
        flex-direction: column;
        gap: 0.4em;

        &.muted {
            opacity: 0.55;
        }

        .cat-caption {
            font-size: 0.74rem;
            color: mcat.$con-ink-faint;
        }
    }

    // ── Readiness hero readout ──────────────────────────────────────────
    .readiness-panel {
        border-color: mcat.$con-amber-line;
        background:
            radial-gradient(
                120% 80% at 100% 0%,
                rgba(255, 176, 32, 0.08),
                transparent 55%
            ),
            mcat.$con-panel;
    }

    .score-lbl {
        font-size: 0.74rem;
        letter-spacing: 0.16em;
        text-transform: uppercase;
        color: mcat.$con-ink-dim;
        margin-bottom: 0.35em;
    }

    .score-figure {
        display: flex;
        align-items: baseline;
        gap: 0.8em;
        flex-wrap: wrap;
        margin-bottom: mcat.$mcat-space-md;

        .score-point {
            font-size: clamp(3.4rem, 11vw, 4.6rem);
            font-weight: 700;
            line-height: 0.95;
            color: mcat.$con-amber;
            text-shadow: 0 0 26px rgba(255, 176, 32, 0.35);
            letter-spacing: -0.02em;
        }

        .score-range {
            font-size: 0.95rem;
            color: mcat.$con-ink-dim;
        }
    }

    .confidence {
        display: inline-flex;
        align-items: center;
        gap: 0.5em;
        margin-top: mcat.$mcat-space-md;
        padding: 0.35em 0.8em;
        border-radius: mcat.$con-radius-sm;
        font-size: 0.76rem;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        font-weight: 600;
        border: 1px solid mcat.$con-line-strong;
        color: mcat.$con-ink-dim;

        .dot {
            width: 0.5em;
            height: 0.5em;
            border-radius: 50%;
            background: currentColor;
        }

        // Confidence is meta (not a recall verdict), so a green/amber cue here
        // grades our *certainty in the estimate*, which is honest.
        &.conf-high {
            color: mcat.$con-correct;
            border-color: color-mix(in srgb, mcat.$con-correct 40%, transparent);
        }
        &.conf-medium {
            color: mcat.$con-amber;
            border-color: mcat.$con-amber-line;
        }
    }

    // ── Per-topic table ─────────────────────────────────────────────────
    .table-wrap {
        overflow-x: auto;
    }

    table {
        width: 100%;
        border-collapse: collapse;
        font-size: 0.85rem;

        th,
        td {
            padding: 7px 10px;
            text-align: right;
            white-space: nowrap;
        }

        th {
            border-bottom: 1px solid mcat.$con-line-strong;
            font-weight: 600;
            font-size: 0.72rem;
            letter-spacing: 0.06em;
            text-transform: uppercase;
            color: mcat.$con-ink-dim;
        }

        td {
            border-bottom: 1px solid mcat.$con-line;
            color: mcat.$con-ink;
        }

        .left {
            text-align: start;
        }

        tbody tr {
            transition: background mcat.$mcat-dur mcat.$mcat-ease;
        }
        tbody tr:hover td {
            background: mcat.$con-panel-2;
        }
        tbody tr.untouched td {
            color: mcat.$con-ink-faint;
        }

        .dash {
            color: mcat.$con-ink-faint;
        }
    }

    .recall-col {
        min-width: 7em;
    }

    // In-cell steel bar behind the always-visible % — magnitude at a glance,
    // value never hidden behind colour (honest: steel, not amber).
    .recall-bar {
        position: relative;
        display: flex;
        justify-content: flex-end;
        align-items: center;

        .fill {
            position: absolute;
            left: 0;
            top: 3px;
            bottom: 3px;
            width: calc(var(--v, 0) * 100%);
            background: mcat.$con-steel-track;
            border-radius: 2px;
        }

        .val {
            position: relative;
        }
    }

    .caption {
        margin-top: 0.7em;
        color: mcat.$con-ink-faint;
        font-size: 0.76rem;
        text-align: center;
    }

    @media (prefers-reduced-motion: reduce) {
        .bar .fill,
        .recall-bar .fill,
        table tbody tr {
            transition: none;
        }
    }
</style>
