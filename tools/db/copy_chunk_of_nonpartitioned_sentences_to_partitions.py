#!/usr/bin/env python3
#
# Copy a chunk of sentences from "story_sentences_nonpartitioned" to "story_sentences_partitioned"
#

import time

from mediawords.db import connect_to_db
from mediawords.util.log import create_logger
from mediawords.util.process import run_alone

log = create_logger(__name__)


def copy_chunk_of_nonpartitioned_sentences_to_partitions():
    """Call PostgreSQL function which creates missing table partitions (if any)."""

    sentences_chunk_size = 1 * 1000 * 1000

    # Wait for an hour between attempts to create new partitions
    delay_between_attempts = 1

    while True:
        log.info("Copying {} sentences to a partitioned table...".format(sentences_chunk_size))

        db = connect_to_db()
        db.query(
            'SELECT copy_chunk_of_nonpartitioned_sentences_to_partitions(%(chunk_size)s)',
            {'chunk_size': sentences_chunk_size}
        )
        db.disconnect()

        log.info("Copied {} sentences, sleeping for {} seconds.".format(sentences_chunk_size, delay_between_attempts))
        time.sleep(delay_between_attempts)


if __name__ == '__main__':
    run_alone(copy_chunk_of_nonpartitioned_sentences_to_partitions)
