TOP_DIR := $(realpath $(CURDIR))
OBJ_DIR := $(TOP_DIR)/build
INPUT_CFGS := $(TOP_DIR)/top_3x3.yml

HAMMER_PYTHONPATH := $(TOP_DIR)/hammer/src:$(TOP_DIR)/hammer/src/hammer-vlsi:$(TOP_DIR)/hammer/src/hammer-tech:$(TOP_DIR)/hammer/src/python-jsonschema-objects:$(TOP_DIR)/hammer/src/jsonschema

export HAMMER_HOME := $(TOP_DIR)/hammer
export HAMMER_VLSI := $(HAMMER_HOME)/src/hammer-vlsi
export PYTHONPATH := $(HAMMER_PYTHONPATH)
export MYPYPATH := $(PYTHONPATH)
export PATH := $(HAMMER_HOME)/src/hammer-shell:$(PATH)

HAMMER_EXEC := env PYTHONPATH=$(HAMMER_PYTHONPATH) HAMMER_HOME=$(HAMMER_HOME) HAMMER_VLSI=$(HAMMER_VLSI) $(TOP_DIR)/hammer_run

$(CURDIR)/.pyyaml_touch:
	pip3 install --user pyyaml
	touch $@

include $(TOP_DIR)/module_top.mk
