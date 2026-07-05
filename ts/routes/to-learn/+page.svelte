<!--
Copyright: Ankitects Pty Ltd and contributors
License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
-->
<script lang="ts">
    import type { NeverLearnedListResponse } from "@generated/anki/tags_pb";
    import { neverLearnedList } from "@generated/backend";
    import * as tr from "@generated/ftl";

    // Group by AAMC section. MileDown is single-rooted under "MileDown::", so
    // the sections live at depth 2 (MileDown::Behavioral, MileDown::Biochemistry,
    // ...); depth 1 would collapse everything into one "MileDown" topic.
    const groupDepth = 2;

    let data: NeverLearnedListResponse | null = null;

    async function load(): Promise<void> {
        // Empty search -> whole collection; backend ANDs in tag:NeverLearned itself.
        data = await neverLearnedList({ groupDepth, search: "" });
    }

    load();
</script>

<div class="con-root to-learn-page">
    {#if data}
        <header class="masthead">
            <span class="unit">ANKINETIC</span>
            <span class="sep">/</span>
            <span class="screen">TO&nbsp;LEARN</span><span class="caret" aria-hidden="true"
            ></span>
        </header>

        {#if data.groups.length === 0}
            <section class="panel">
                <p class="empty">{tr.statisticsToLearnEmpty()}</p>
            </section>
        {:else}
            <div class="group-stack">
                {#each data.groups as group (group.tag)}
                    <section class="panel group enter">
                        <header class="group-head">
                            <h2 class="group-title">{group.tag}</h2>
                            <span class="count-chip">
                                {group.cards.length} cards
                            </span>
                        </header>
                        <ul class="card-list">
                            {#each group.cards as card (card.cardId)}
                                <li>{card.label}</li>
                            {/each}
                        </ul>
                    </section>
                {/each}
            </div>
        {/if}
    {/if}
</div>

<style lang="scss">
    @use "../../../sass/mcat-tools.scss" as mcat;

    .to-learn-page {
        @include mcat.con-root;
        max-width: 62em;
        margin: 0 auto;
        min-height: 100%;
        padding: clamp(0.9rem, 2.5vw, 1.6rem);
        display: flex;
        flex-direction: column;
        gap: mcat.$mcat-space-md;
    }

    .masthead {
        display: flex;
        align-items: baseline;
        gap: 0.55em;
        font-size: 0.78rem;
        letter-spacing: 0.14em;
        color: mcat.$con-ink-faint;

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

    .panel {
        @include mcat.con-panel;
        padding: clamp(0.9rem, 2.2vw, 1.35rem);
    }

    .enter {
        @include mcat.con-enter;
    }

    .empty {
        color: mcat.$con-ink-dim;
        font-family: mcat.$con-sans;
        text-align: center;
        margin: 0.5em 0;
    }

    .group-stack {
        display: flex;
        flex-direction: column;
        gap: mcat.$mcat-space-md;
    }

    .group-head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: mcat.$mcat-space-sm;
        margin-bottom: mcat.$mcat-space-sm;
        padding-bottom: mcat.$mcat-space-sm;
        border-bottom: 1px solid mcat.$con-line;
    }

    .group-title {
        font-size: 0.95rem;
        font-weight: 700;
        letter-spacing: 0.02em;
        margin: 0;
        color: mcat.$con-ink;
    }

    .count-chip {
        @include mcat.con-chip(mcat.$con-amber);
    }

    .card-list {
        list-style: none;
        margin: 0;
        padding: 0;
        font-family: mcat.$con-sans;

        li {
            position: relative;
            padding: 0.45em 0 0.45em 1.3em;
            line-height: 1.4;
            color: mcat.$con-ink;

            // A mono "prompt" marker instead of a bullet.
            &::before {
                content: "›";
                position: absolute;
                left: 0.1em;
                top: 0.42em;
                font-family: mcat.$con-mono;
                color: mcat.$con-amber;
            }

            & + li {
                border-top: 1px solid mcat.$con-line;
            }
        }
    }
</style>
