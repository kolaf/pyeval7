# Copyright 2014 Anonymous7 from Reddit, Julian Andrews
#
# This software may be modified and distributed under the terms
# of the MIT license.  See the LICENSE file for details.

import cython
from xorshift_rand cimport randint
from evaluate cimport cy_evaluate
from cards cimport cards_to_mask


cdef extern from "stdlib.h":
    ctypedef unsigned long size_t
    void *malloc(size_t n_bytes)
    void free(void *ptr)


cdef cython.ulonglong card_masks_table[52]


cdef cython.uint load_card_masks():
    for i in range(52):
        card_masks_table[i] = 1 << i
    return 0


load_card_masks()


cdef cython.uint filter_options(cython.ulonglong *source, 
        cython.ulonglong *target, 
        cython.uint num_options, 
        cython.ulonglong dead):
    """
    Removes all options that share a dead card
    Returns total number of options kept
    """
    cdef cython.ulonglong options
    cdef cython.uint total = 0
    for 0 <= s < num_options:
        option = source[s]
        if option & dead == 0:
            target[total] = option
            total += 1
    return total


cdef cython.ulonglong deal_card(cython.ulonglong dead):
    cdef cython.uint cardex
    cdef cython.ulonglong card
    while True:
        cardex = randint(52)
        card = card_masks_table[cardex]
        if dead & card == 0:
            return card


cdef cython.float hand_vs_range_monte_carlo(cython.ulonglong hand, 
        cython.ulonglong *options, 
        cython.int num_options, 
        cython.ulonglong start_board, 
        cython.int num_board, 
        cython.int iterations):
    """
    Return equity of hand vs range.
    Note that only unweighted ranges are supported.
    Note that only heads-up evaluations are supported.
    
    hand is a two-card hand mask
    options is an array of num_options options for opponent's two-card hand
    board is a hand mask of the board; num_board says how many cards are in it
    """
    cdef cython.uint count = 0
    cdef cython.uint option_index = 0
    cdef cython.ulonglong option
    cdef cython.ulonglong dealt
    cdef cython.uint hero
    cdef cython.uint villain
    cdef cython.ulonglong board
    for 0 <= i < iterations:
        # choose an option for opponent's hand
        option = options[option_index]
        option_index += 1
        if option_index >= num_options:
            option_index = 0
        # deal the rest of the board
        dealt = hand | option
        board = start_board
        for j in range(5 - num_board):
            board |= deal_card(board | dealt)
        hero = cy_evaluate(board | hand, 7)
        villain = cy_evaluate(board | option, 7)
        if hero > villain:
            count += 2
        elif hero == villain:
            count += 1
    return 0.5 * <cython.double>count / <cython.double>iterations


def py_hand_vs_range_monte_carlo(py_hand, py_villain, py_board, 
        py_iterations):
    cdef cython.ulonglong hand = cards_to_mask(py_hand)
    cdef cython.int num_options = len(py_villain)
    cdef cython.ulonglong *options = <cython.ulonglong*>malloc(
            sizeof(cython.ulonglong) * num_options)
    cdef cython.ulonglong start_board = cards_to_mask(py_board)
    cdef cython.int num_board = len(py_board)
    cdef cython.int iterations = py_iterations
    cdef cython.float equity  # DuplicatedSignature
    cdef cython.ulonglong mask
    for index, option in enumerate(py_villain):
        options[index] = cards_to_mask(option[0])
        # This strips and ignores the weight.
    num_options = filter_options(options, options, num_options, 
            start_board | hand)
    equity = hand_vs_range_monte_carlo(hand, options, num_options, 
            start_board, num_board, iterations)
    free(options)
    return equity


cdef cython.float hand_vs_range_exact(cython.ulonglong hand, 
        cython.ulonglong *options, 
        cython.int num_options, 
        cython.ulonglong complete_board):
    # I think it might be okay (good) not to randomly sample options, but
    # instead to evenly sample them. (Still with a randomly sampled board, of
    # course.) This'll make the results converge faster. We can only do this
    # because we know that every option is equally likely (unlike, for example,
    # range vs. range equity calculation).
    cdef cython.uint wins = 0
    cdef cython.uint ties = 0
    cdef cython.ulonglong option  # @DuplicatedSignature
    cdef cython.uint hero = cy_evaluate(complete_board | hand, 7)
    cdef cython.uint villain  # @DuplicatedSignature
    for i in range(num_options):
        # choose an option for opponent's hand
        option = options[i]
        villain = cy_evaluate(complete_board | option, 7)
        if hero > villain:
            wins += 1
        elif hero == villain:
            ties += 1
    return (wins + 0.5 * ties) / <cython.double>num_options


def py_hand_vs_range_exact(py_hand, py_villain, py_board):
    cdef cython.ulonglong hand = cards_to_mask(py_hand)  # @DuplicatedSignature
    cdef cython.int num_options = len(py_villain)  # @DuplicatedSignature
    cdef cython.ulonglong *options = <cython.ulonglong*>malloc(
            sizeof(cython.ulonglong) * num_options)  # @DuplicatedSignature
    cdef cython.ulonglong complete_board = cards_to_mask(py_board)
    cdef cython.float equity
    cdef cython.ulonglong mask  # @DuplicatedSignature
    cdef cython.ulonglong dead = complete_board | hand  
    for index, option in enumerate(py_villain):
        options[index] = cards_to_mask(option[0])
        # This strips and ignores the weight
    num_options = filter_options(options, options, num_options, 
            complete_board | hand)
    equity = hand_vs_range_exact(hand, options, num_options, complete_board)
    free(options)
    return equity


cdef void all_hands_vs_range(cython.ulonglong *hands, 
        cython.uint num_hands,
        cython.ulonglong *all_options, 
        cython.uint num_options,
        cython.ulonglong board, 
        cython.uint num_board,
        cython.long iterations, 
        cython.float *result):
    """
    Return equity of each hand, versus range.
    Note that only unweighted ranges are supported.
    Note that only heads-up evaluations are supported.
    
    hands are two-card hand mask; num_hands is how many
    options is an array of num_options options for opponent's two-card hand
    board is a hand mask of the board; num_board says how many cards are in it
    iterations is iterations to perform
    result is a preallocated array in which to put results (order corresponds
        to order of hands)
    """
    cdef cython.float equity  # @DuplicatedSignature
    cdef cython.ulonglong hand
    cdef cython.uint current_num_options
    cdef cython.ulonglong *options = <cython.ulonglong *>malloc(
            sizeof(cython.ulonglong) * num_options)
    for 0 <= i < num_hands:
        hand = hands[i]
        # Have to do card removal effects at this point - on a hand by hand basis.
        current_num_options = filter_options(all_options, options, 
                num_options, board | hand)
        if current_num_options == 0:
            result[i] = -1  # Villain's range makes this hand impossible for hero.
            continue
        if num_board == 5 and current_num_options <= iterations:
            equity = hand_vs_range_exact(hand, options, current_num_options, 
                    board)
        else:
            equity = hand_vs_range_monte_carlo(hand, options, 
                    current_num_options, board, num_board, iterations)
        result[i] = equity
    free(options)
        

def py_all_hands_vs_range(py_hero, py_villain, py_board, py_iterations):
    """
    Return dict mapping hero's hand to equity against villain's range on this board.
    
    hero and villain are ranges.
    board is a list of cards.
    
    TODO: consider randomising the order of opponent's hands at this point
    so that the evenly distributed sampling in hand_vs_range is unbiased.

    Board pre-filtering has been disabled. This is inefficient, and will 
    be addressed by a planned refactoring.
    """
    cdef cython.ulonglong *hands = <cython.ulonglong *>malloc(
            sizeof(cython.ulonglong) * len(py_hero))
    cdef cython.uint num_hands
    cdef cython.ulonglong *options = <cython.ulonglong *>malloc(
            sizeof(cython.ulonglong) * len(py_villain))
    cdef cython.uint num_options
    cdef cython.ulonglong board  # @DuplicatedSignature
    cdef cython.uint num_board
    cdef cython.long iterations = <cython.long>py_iterations
    cdef cython.float *result = <cython.float *>malloc(
            sizeof(cython.float) * len(py_hero))
   
    num_hands = 0
    for hand, weight in py_hero:
        hands[num_hands] = cards_to_mask(hand)
        num_hands += 1
        
    num_options = 0
    for option, weight in py_villain:
        options[num_options] = cards_to_mask(option)
        num_options += 1
        
    board = cards_to_mask(py_board)
    num_board = len(py_board)

    all_hands_vs_range(hands, num_hands, options, num_options, board, 
            num_board, iterations, result)
    
    py_result = {}
    for i, (hand, weight) in enumerate(py_hero):
        if result[i] != -1:
            py_result[hand] = result[i]
    free(hands)
    free(options)
    free(result)
    
    return py_result
