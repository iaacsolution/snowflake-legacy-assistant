"""Tests du comparateur de eval_text2sql.py — sans appeler Snowflake.

POURQUOI CE FICHIER
    Le score du golden dataset repose entierement sur compare() : si le
    comparateur est trop laxiste, une regression d'Analyst passe pour un succes ;
    s'il est trop strict, une reponse juste est comptee fausse et on cherche un
    probleme qui n'existe pas. C'est la piece qui decide de ce que veut dire
    "10/10", et elle n'etait couverte par aucun test jusqu'au J5.

    as_sequence, scalar_match et compare sont des fonctions pures : aucun reseau,
    aucun credit, aucune connexion. Les cas ci-dessous encodent les regles
    ecrites dans leurs docstrings, y compris les pieges reels du jeu de donnees
    (metric_value est typee FLOAT, donc tout compteur revient en float).

        pytest src/test_eval_compare.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pytest  # noqa: E402

from eval_text2sql import as_sequence, compare, scalar_match  # noqa: E402

# --- as_sequence : tout ramener a une liste plate de scalaires ----------------


@pytest.mark.parametrize(
    "entree,attendu",
    [
        (None, []),
        (877739.0, [877739.0]),
        ([3, 1], [3, 1]),
        # Un resultat SQL est une liste de lignes, chaque ligne un tuple.
        ([("PaymentProcessorBean",)], ["PaymentProcessorBean"]),
        ([(3, 1)], [3, 1]),
        (
            [("analyze", 877739.0), ("report", 2711957.0)],
            ["analyze", 877739.0, "report", 2711957.0],
        ),
    ],
)
def test_as_sequence_aplatit(entree, attendu):
    assert as_sequence(entree) == attendu


# --- scalar_match : comparaison par valeur, pas par type ---------------------


def test_int_et_float_sont_egaux():
    """metric_value est typee FLOAT : 4 attendu doit matcher 4.0 obtenu."""
    assert scalar_match(4, 4.0)
    assert scalar_match(4.0, 4)


def test_tolerance_numerique():
    """66.666667 vs 66.67 : l'arrondi d'Analyst ne doit pas compter comme faux."""
    assert scalar_match(66.666667, 66.67, tol=0.05)
    assert not scalar_match(877739.0, 2676441.0)


def test_nombre_en_texte():
    """Une valeur revenant en chaine depuis JSON reste comparable."""
    assert scalar_match(877739.0, "877739")


def test_texte_insensible_casse_et_espaces():
    assert scalar_match("ClientServiceBean", "  clientservicebean ")


def test_booleen_jamais_traite_comme_nombre():
    """True != 1 ici : un statut booleen ne doit pas matcher un compteur."""
    assert not scalar_match(True, 1)
    assert not scalar_match(1, True)
    assert scalar_match(True, True)


def test_valeur_incomparable_ne_leve_pas():
    assert not scalar_match(4, None)
    assert not scalar_match(4, "quatre")


# --- compare : chaque valeur attendue couvre une cellule DISTINCTE ------------


def test_scalaire_trouve_dans_une_ligne_a_une_colonne():
    ok, motif = compare(877739.0, [(877739.0,)])
    assert ok, motif


def test_ordre_des_colonnes_indifferent():
    """Analyst ajoute legitimement une colonne d'etiquette, dans un ordre libre."""
    ok, motif = compare([3, 1], [(1, 3)])
    assert ok, motif


def test_colonne_supplementaire_toleree():
    """La phase a cote de la duree ne doit pas penaliser une reponse juste."""
    ok, motif = compare(877739.0, [("analyze", 877739.0)])
    assert ok, motif


def test_valeur_absente_rejetee():
    ok, motif = compare(877739.0, [(2676441.0,)])
    assert not ok
    assert "absente" in motif


def test_resultat_vide_rejete():
    ok, motif = compare(877739.0, [])
    assert not ok
    assert motif == "resultat vide"


def test_aucune_valeur_attendue_rejetee():
    ok, motif = compare(None, [(1,)])
    assert not ok
    assert motif == "aucune valeur attendue"


def test_cellules_distinctes_exigees():
    """Deux valeurs attendues identiques exigent DEUX cellules, pas une seule.

    C'est la regle qui empeche un resultat a une colonne de satisfaire par
    hasard une attente a deux valeurs.
    """
    ok, _ = compare([1, 1], [(1,)])
    assert not ok
    ok, motif = compare([1, 1], [(1, 1)])
    assert ok, motif
