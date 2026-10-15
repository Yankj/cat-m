// Feeds pending proactive suggestions into the next chat turn as `proactive_suggestion` SSE events
// (payload = toSuggestion(event), 方块's ProactiveSuggestion). Each suggestion is delivered to chat at most once.
import { toSuggestion } from './decision.mjs';
export function createSuggestionFeed({ store, allow = () => false, limit = 3, now = () => Date.now() }) {
  return {
    async claimForTurn({ subjectID, conversationID = null, turnID = null }) {
      if (!allow(subjectID) || !store.claimSuggestionsForChat) return [];
      const rows = await store.claimSuggestionsForChat(subjectID, { limit, at: new Date(now()).toISOString(), conversationID, turnID });
      return rows.map(toSuggestion);
    },
  };
}
