"""Tests de depouillement de la reponse de l'agent — sans appeler Snowflake.

POURQUOI CE FICHIER
    Le seul endroit ou src/ask.py peut se tromper silencieusement est la lecture
    du payload : le nombre de blocs, leur ordre et leur presence varient avec la
    question posee. Une question documentaire ne produit aucun SQL ; une question
    mixte declenche deux outils ; une version future de l'API peut introduire un
    type de bloc inconnu. Tester cela contre le vrai service couterait un appel
    par cas et resterait tributaire de ce que l'agent decide ce jour-la.

    Les payloads ci-dessous sont calques sur l'exemple de la documentation
    Cortex Agents (verifiee le 21/08/2026). Ils ne prouvent pas que l'API renvoie
    bien cette forme — seul un appel reel le prouve, et --raw sert a cela. Ils
    prouvent que le code resiste aux variations de forme au lieu de parier sur un
    index.

    Aucun reseau, aucun credit.

        python src/test_ask_parse.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ask import blocs, depouiller, payload_depuis_sse

# Payload calque sur l'exemple de la doc Cortex Agents (21/08/2026),
# question mixte : Analyst puis Search.
p = {
  "role": "assistant",
  "content": [
    {"type": "thinking", "thinking": {"text": "Il faut d'abord la classe la plus lente."}},
    {"type": "tool_use", "tool_use": {"tool_use_id": "t1", "type": "cortex_analyst_text_to_sql",
      "name": "BenchAnalyst", "input": {"query": "classe la plus lente"}}},
    {"type": "tool_result", "tool_result": {"tool_use_id": "t1", "status": "success",
      "content": [{"type": "json", "json": {"sql": "SELECT classe FROM x",
        "query_id": "01b2", "result_set": {"resultSetMetaData": {"rowType": [{"name": "CLASSE"}]},
        "data": [["PaymentProcessorBean"]]}}}]}},
    {"type": "tool_use", "tool_use": {"tool_use_id": "t2", "type": "cortex_search",
      "name": "DocSearch", "input": {"query": "PaymentProcessorBean"}}},
    {"type": "tool_result", "tool_result": {"tool_use_id": "t2", "status": "success",
      "content": [{"type": "json", "json": {"searchResults": [
        {"DOC_ID": "9", "SOURCE_FILE": "specs.md", "DOC_CONTENT": "Le bean traite les paiements."}]}}]}},
    {"type": "text", "text": "La classe la plus lente est PaymentProcessorBean.",
     "annotations": [{"type": "cortex_search_citation", "doc_title": "specs.md", "text": "..."}]},
  ],
  "metadata": {"run_id": "42", "usage": {"tokens_consumed": 1234}},
}
v = depouiller(p)
assert v["reponse"].startswith("La classe la plus lente"), v["reponse"]
assert [o["nom"] for o in v["outils"]] == ["BenchAnalyst", "DocSearch"], v["outils"]
assert v["resultats"][0]["sql"] == "SELECT classe FROM x"
assert v["resultats"][0]["lignes"] == [["PaymentProcessorBean"]]
assert v["resultats"][0]["colonnes"] == ["CLASSE"]
assert v["resultats"][1]["documents"][0]["titre"] == "specs.md"
assert v["citations"][0]["titre"] == "specs.md"
print("OK  question mixte : 2 outils, SQL, lignes, documents, citation")

# Enrobage sous "message" (forme Analyst du J3) et sous "response".
assert blocs({"message": {"content": [{"type": "text", "text": "a"}]}})
assert blocs({"response": {"content": [{"type": "text", "text": "a"}]}})
print("OK  les trois enrobages sont acceptes")

# Question documentaire seule : aucun SQL, l'ordre des blocs n'est pas le meme.
p2 = {"content": [
    {"type": "tool_use", "tool_use": {"tool_use_id": "a", "type": "cortex_search", "name": "DocSearch", "input": {}}},
    {"type": "tool_result", "tool_result": {"tool_use_id": "a", "status": "success", "content": []}},
    {"type": "text", "text": "Les factures sont generees par InvoiceGeneratorBean."}]}
v2 = depouiller(p2)
assert v2["resultats"][0]["sql"] is None and v2["outils"][0]["nom"] == "DocSearch"
print("OK  question documentaire : aucun SQL, pas de plantage")

# Hors perimetre : aucun outil, un seul bloc texte.
v3 = depouiller({"content": [{"type": "text", "text": "Hors perimetre."}]})
assert v3["outils"] == [] and v3["reponse"] == "Hors perimetre."
print("OK  reponse sans outil")

# Bloc inconnu d'une version future : ignore, pas d'exception.
v4 = depouiller({"content": [{"type": "chart", "chart": {"spec": "..."}},
                             {"type": "text", "text": "ok"}]})
assert v4["reponse"] == "ok" and "chart" in v4["types_vus"]
print("OK  bloc de type inconnu ignore")

# Repli SSE : c'est le dernier evenement JSON qui fait foi.
sse = 'event: response.text.delta\ndata: {"text":"La "}\n\nevent: response\ndata: {"role":"assistant","content":[{"type":"text","text":"La reponse complete."}]}\n\ndata: [DONE]\n'
assert depouiller(payload_depuis_sse(sse))["reponse"] == "La reponse complete."
print("OK  repli SSE")

# --- Forme reellement observee le 21/08/2026 -----------------------------------
# Les payloads ci-dessus viennent de la doc. Celui-ci est calque sur la trace
# d'un appel reel a LEGACY_ASSISTANT, et differe sur trois points : l'outil
# Analyst se dedouble en `system_agentic_semantic_context` + `system_execute_sql`,
# des tool_result portent statut=error avant qu'un suivant aboutisse, et un bloc
# `suggested_queries` ferme la reponse. C'est le cas qui casserait un parseur
# indexant content[-1].
p5 = {"role": "assistant", "content": [
    {"type": "thinking", "thinking": {"text": "Question chiffree sur une duree."}},
    {"type": "tool_use", "tool_use": {"tool_use_id": "s0", "type": "system_agentic_semantic_context",
      "name": "BenchAnalyst", "input": {"pruning_question": "duree totale de la phase analyze"}}},
    {"type": "tool_result", "tool_result": {"tool_use_id": "s0", "status": "success", "content": []}},
    {"type": "tool_use", "tool_use": {"tool_use_id": "s1", "type": "system_execute_sql",
      "name": "system_execute_sql", "input": {"sql": "SELECT duree_totale_ms FROM __metriques"}}},
    {"type": "tool_result", "tool_result": {"tool_use_id": "s1", "status": "error",
      "content": [{"type": "json", "json": {"sql": "SELECT duree_totale_ms FROM __metriques"}}]}},
    {"type": "tool_use", "tool_use": {"tool_use_id": "s2", "type": "system_execute_sql",
      "name": "system_execute_sql", "input": {"sql": "SELECT SUM(...) FROM __metriques"}}},
    {"type": "tool_result", "tool_result": {"tool_use_id": "s2", "status": "success",
      "content": [{"type": "json", "json": {"sql": "SELECT SUM(...) FROM __metriques",
        "result_set": {"resultSetMetaData": {"rowType": [{"name": "DUREE_TOTALE_MS"}]},
        "data": [["877739"]]}}}]}},
    {"type": "text", "text": "La phase analyze a dure 877 739 ms."},
    {"type": "suggested_queries", "suggested_queries": {"queries": ["et la phase report ?"]}},
]}
v5 = depouiller(p5)
assert v5["reponse"] == "La phase analyze a dure 877 739 ms.", v5["reponse"]
# le texte final est lu malgre le bloc qui le suit
assert v5["types_vus"][-1] == "suggested_queries"
# l'echec intermediaire est visible, il n'ecrase pas le succes qui suit
statuts = [r["statut"] for r in v5["resultats"]]
assert statuts == ["success", "error", "success"], statuts
assert v5["resultats"][-1]["lignes"] == [["877739"]]
# les deux appels systeme sont attribues, aucun "?" d'identifiant perdu
assert [o["nom"] for o in v5["outils"]] == [
    "BenchAnalyst", "system_execute_sql", "system_execute_sql"], v5["outils"]
assert all(r["nom"] != "?" for r in v5["resultats"])
print("OK  forme reelle : outil Analyst dedouble, retry en erreur, suggested_queries")
