relationship between the beans. The only difference from previous exercises is the change in the JNDI name element tag for the Address home interface:

<local-jndi-name>AddressHomeLocal</local-jndi-name>

Because the Home interface for the Address is local, the tag is <local-jndi-name> rather than <indi-name>.

the technician can -robots.jarxml descriptor file contains a number of new sections and elements

that can be added to the system. The new sections will wait until the next

exercise, but there are some other changes to observe and examine.

the contains the a section mapping the attributes from the ipv4-ip

table in addition to a new section related to the

automatic key generation used for primary key values in this box:

```xml

<weblogic-rdbms-bean>

  <ejp-name>AddressJUE</ejp-name>

  <data-source-name>itan-dataSource</data-source-name>

  <table-name>ADDRESS</table-name>

  <field-map>

    <cmp-field>id</cmp-field>

    <dbms-column>ID</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>street</cmp-field>

    <dbms-column>STREET</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>city</cmp-field>

    <dbms-column>CITY</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>state</cmp-field>

    <dbms-column>STATE</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>zip</cmp-field>

    <dbms-column>ZIP</dbms-column>

  </field-map>

  <!-- Automatically generate the value of ID in the database on

inserts using sequence table -->

  <automatic-key-generation>

    <generator-type>NAMED_SEQUENCE_TABLE</generator-type>

    <generator-name>ADDRESS_SEQUENCE</generator-name>

    <key-cache-size>10</key-cache-size>

  </automatic-key-generation>

</weblogic-rdbms-bean>

```
